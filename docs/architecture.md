# How CraftNet works

How the pieces fit **today**. The milestone records under
[`implementation/`](implementation/) say how it got here and the
[ADRs](adr/) say why each decision went the way it did; this describes the
thing as it stands.

Vocabulary is [`CONTEXT.md`](../CONTEXT.md). The wire is
[`protocol/v1.md`](protocol/v1.md).

## The shape

```text
                    craftnetd  (outside Minecraft)
                         │  one WebSocket per World
                    Central Server        world infrastructure, not an ISP
                         │
                        ISP                any number per World
                    ┌────┴────┐
                 Router     Router         one per Customer Network
                ┌───┴───┐  ┌───┴───┐
             Computer  ...  Computer
```

Every edge is a **parent-child relationship** with its own durable credential.
Nothing skips a level: a Computer reaches another Customer Network through its
router, its ISP, and the Central Server, even when both networks belong to the
same ISP. The Central Server is the sole interconnection point
([ADR 0007](adr/0007-centralize-interconnection-with-exact-route-registrations.md)).

## Who owns what

The authority model is the load-bearing idea. Each role is the **only** thing
that may decide its own slice, and a message from a neighbour is checked against
that rather than believed.

| Role | Owns |
|---|---|
| Computer | its application, and nothing about the network |
| Customer Router | its RFC 1918 pool, its Address Bindings, local DNS, its Exposed Services, its NAT Flows |
| ISP | its Provider Allocation, which Customer Routers it serves, their Provider Addresses |
| Central Server | the World identity, the ISP registry, the RFC 6598 allocator, the route directory, Network Status |
| `craftnetd` | external identity, Device Credentials, Access Tokens, the operation allowlist, history |

Two consequences worth holding onto:

- **A parent may not rewrite what a child owns.** An ISP's configuration
  snapshot names a router's `customer_network_id` and `provider_address`; if it
  named the router's pool, the router would ignore that part.
- **Authority stays in world.** Stop `craftnetd` and addressing, names, routing,
  NAT, and Network Status all carry on. Only External Operations fail
  ([ADR 0002](adr/0002-keep-network-authority-in-world.md)).

## Addresses and names

Customer addresses are RFC 1918 and **deliberately overlap**: Home and Farm both
hand out `192.168.1.20`. An address means something only inside its own Customer
Network, and what disambiguates a reply is the paired NAT Flow, never the
address ([ADR 0005](adr/0005-use-network-scoped-addresses-without-subnets.md),
[ADR 0006](adr/0006-use-paired-flows-for-simplified-nat.md)).

Provider Addresses are RFC 6598 (`100.64.0.0/10`), delegated by the Central
Server to ISPs in non-overlapping blocks.

Names are a delegated hierarchy resolved by walking **upward** to whoever is
authoritative, with no central directory:

```text
harvester                      inside the asking Computer's own network
harvester.farm                 anywhere on the same ISP
harvester.farm.acme            anywhere in the World
harvester.farm.acme.craft      explicit
api.craft                      the External Application — and it has no address
```

There is no subnet mask and no routing protocol. The route directory holds **one
exact entry per Customer Network**; a range organises allocation, not delivery.

## The code

Three shared Lua packages, four role packages that compose them, one Go binary.

| Package | What it hides |
|---|---|
| `craftnet-protocol` | the wire: canonical JSON, SHA-256 and HMAC in pure Lua, key derivation, schemas, the handshakes, counters, replay rejection, framing, correlation, limits |
| `craftnet-core` | pure role state transitions — no file, no modem, no timer, no clock |
| `craftnet-runtime` | the orchestration: snapshots, secrets, links, enrollment, connectivity, screens, and the CraftOS adapters |
| `craftnet-central`, `-isp`, `-router`, `-computer` | composition roots — wiring and what is genuinely their own |

A caller exchanges semantic messages and never calculates a MAC or a canonical
form. A role decides and never performs I/O.

`craftnetd` is one Go binary, one SQLite file, one origin
([ADR 0009](adr/0009-use-a-single-go-service-with-sqlite.md)): `store`,
`identity`, `operations`, `gateway`, `worldview`, `web`, and `app` as the
composition root — the only place an operation is registered.

### The effect seam

This is the pattern everything else hangs off.

```text
input ──▶ craftnet-core handler ──▶ effects (data)
                                        │
                            craftnet-runtime performs them
                                        │
                              result ──▶ back in as the next input
```

A handler answers "what should happen", never "make it happen". The runtime
carries out each effect and feeds the outcome back, so a failed write or a
failed send reaches the authority that cared about it instead of disappearing
into an adapter. It is also why a whole World can be driven from a table in a
test and still exercise the transitions that run in Minecraft.

## What travels

### Enrollment, once per relationship

A one-time secret — an ISP Enrollment Token, a Router Enrollment Token, or a LAN
Password, carried by an Operator from one screen to the next — proves a
four-message exchange. Both sides derive a **durable relationship credential**
from the transcript. The secret is then spent.

Afterwards a reconnect is a three-message exchange under that credential
producing a fresh session key. An old session is never resumed
([ADR 0004](adr/0004-authenticate-modem-sessions-with-derived-keys.md)).

Transport is raw modem channels
([ADR 0003](adr/0003-build-craftnet-on-raw-modem-channels.md)): a public
discovery channel to find a parent, an assigned operational channel afterwards.

### A local request

`alex-pc` calls `wall-display`, both on Home. It still goes to the router —
there is no direct Computer-to-Computer path — and the router delivers it
locally. **No NAT Flow, no Provider Address, nothing leaves.**

### A cross-network request

`alex-pc` on Home calls `harvester` on Farm:

```text
alex-pc ─▶ Home router ─▶ ISP ─▶ Central Server ─▶ ISP ─▶ Farm router ─▶ harvester
```

- The Home router replaces `source` from the authenticated session and opens a
  NAT Flow, sending its identifier along.
- The ISP checks the router speaks for its own Customer Network.
- The Central Server checks the ISP owns the source route, looks up the exact
  destination route, and refuses a disabled network.
- The Farm router requires the service to be **explicitly exposed** — unsolicited
  inbound is `inbound_denied` — and opens the far half of the flow pair.
- The reply retraces the flow pair. That is what tells the two Computers holding
  `192.168.1.20` apart.

### An external call

`craftnet call api.craft test.identity`:

```text
Computer ─▶ router ─▶ ISP ─▶ Central Server ═══▶ craftnetd
   external_call (no destination — the kind is the destination)
                              │
                      stamps the ancestry from the route directory
```

Every hop **derives** ancestry rather than believing a claim, so what reaches
`craftnetd` — World, ISP, Customer Network, router, Computer, address — was
never written by the caller. The Computer registers once through that ancestry,
holds a two-minute Access Token, and the answer comes back as an ordinary
`service_response` retracing the same NAT Flow
([ADR 0010](adr/0010-name-the-external-application-with-its-own-message-kind.md)).

One WebSocket per World, opened outward by the Central Server
([ADR 0008](adr/0008-use-one-semantic-gateway-session-per-world.md)). No other
role opens one, and an operation is a **name on an allowlist**, never a URL.

### Telemetry

Roles record Traffic Events — metadata only, redacted at construction, in
bounded rolling buffers. The Central Server sends a full topology snapshot when
a Gateway Session opens, then batches its events with durable sequences, so a
disconnect shows at the far end as a gap rather than a plausible present.

Today only the Central Server's own events reach `craftnetd`; routers and ISPs
record theirs locally and nothing carries them upward. See
[Milestone 9](implementation/milestone-9.md).

## Restarts

Durable state is a versioned atomic snapshot with one backup; a corrupt primary
falls back, and two unreadable copies stop the role rather than inventing a
state to continue from.

What survives: identity, credentials, bindings, routes, allocations, Network
Status, and the generation counters. What does not: sessions, NAT Flows,
correlation records, and caches. **In-flight work fails rather than resuming** —
CraftNet never decides on its own to do again what a player asked for once.

## Deliberately absent

Not gaps. Decisions, recorded as such in
[the release notes](releases/v0.1.0.md):

byte-compatible Ethernet/IPv4/TCP/UDP/BGP/ARP · checksums, fragmentation, TTL ·
subnet masks · a routing protocol · access to arbitrary internet origins ·
payload encryption · high availability or a second Central Server · VLANs and
trunking · automatic address eviction · multi-World federation · a downgrade
path.
