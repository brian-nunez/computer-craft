# Milestone 5 — Central and ISP internetwork

Status: **simulator half complete on 2026-09-09. The in-world half has not been
run** — see [Gate evidence](#gate-evidence).

Milestone 5 joins the Customer Networks together. `craftnet-isp` and
`craftnet-central` complete the hierarchy, one-time enrollment tokens carry an
Operator from one Computer to the next, and traffic crosses from Home to Farm
the long way round — through the Central Server, which is the only
interconnection point.

## Delivered

### `craftnet-central` and `craftnet-isp`

| Package | Owns |
|---|---|
| `central` | Provisioning from the External Application's bundle, the ISP registry, ISP Enrollment Tokens, Network Status, topology |
| `isp` | Its own name before it has an identity, enrolling upward, Provider Address assignment, Router Enrollment Tokens, per-router Operational Channels |

Both add `setup`, `token`, and `startup` programs. `craftnet-router` gains
`uplink`, which puts an existing Customer Network onto CraftNet.

### One-time enrollment tokens

`craftnet-protocol/tokens` derives a token from the issuing role's own root
secret and a durable counter: the Central Server from the World Key, an ISP from
its own Credential. Sixteen Crockford base32 characters in four groups — short
enough to read off one screen and type into another, and forgiving of the
characters people actually mistype. A parent stores no token, only which
counters it has spent.

### Shared enrollment

Every parent-child boundary in CraftNet enrolls identically, so the exchange
moved into `craftnet-runtime/enroll` and the role packages now say only what is
theirs: which secrets are currently valid, what to assign, and what to do with
the credential. `craftnet-router/lan` and `craftnet-computer/join` shrank to
thin wrappers over it.

`craftnet-runtime/adapter_modem` became Logical Interfaces: one transport over
several modems, binding upstream and downstream to different ones, with the
channel deciding which modem a frame leaves on.

## Gate evidence

### Automated — complete

206 Lua tests, green on Lua 5.2, 5.4, 5.5, and LuaJIT.

`tests/lua/role_internet_test.lua` stands up the whole World the way an Operator
would: a bundle from the External Application, then tokens carried from screen to
screen, then Computers joining with a LAN Password. Nothing is written into a
node's state by hand.

| Gate requirement | Evidence |
|---|---|
| Scenario 1 — the hierarchy is provisioned and matches the fixture | one ISP, two Customer Networks, distinct Provider Addresses, every network enabled |
| A spent token cannot be used again | a second ISP presenting it is refused, and nothing is registered |
| Bypass messages are ignored | rubbish on the Central Server's discovery channel changes nothing |
| Scenario 3 — identical `.20` addresses never collide | both networks hold `.20` and `.21`; Central tells them apart by identity |
| Scenario 6 — Home→Farm visits Acme twice around Central | the Central Server records the forward; every flow and correlation closes behind the reply |
| Replies reach Home's `.20`, not Farm's | the bystanders holding the same addresses see no part of it |
| Scenario 7 — unsolicited inbound fails | `inbound_denied`, and the Computer never sees the request |
| Removing a route changes reachability without deleting anything | `route_not_found`; Farm keeps its Address Bindings |
| Disabling and restoring a network | `network_disabled`, every registration survives, traffic resumes with no re-enrollment |
| An offline ISP makes routes unreachable without losing them | route and allocation both survive |
| Every Provider Allocation is disjoint | four ISPs, four non-overlapping blocks |
| No ISP can claim another ISP's route | `forbidden_operation`; the owner keeps it |

`ccpm_install_test.lua` now installs all four role packages, materialises each
install on a real disk, and loads it — so a manifest that forgot a module fails
in CI rather than on a Computer. It caught exactly that twice during this
milestone.

### In-world — not run

The gate also asks for "the in-world topology". I have no Minecraft here, so
that half is **unverified**, and written up as a runnable checklist at
[`acceptance/milestone-5-in-world.md`](acceptance/milestone-5-in-world.md).

Until it is run, treat as untested: Ender modems and real range, Logical
Interfaces over two physical modems, the `fs` and `term` adapters, `ccpm` over
real HTTP, `craftnetprov`, and tokens carried by hand between screens.

- [ ] In-world acceptance run completed

## Decisions made inside this milestone

- **A parent assigns less than a child's complete configuration.** Milestone 3
  deferred this; Milestone 5 made the cost concrete. An ISP has never been told
  a Customer Router's LAN address, pool, or channel, so to satisfy the old
  schema it would have had to invent them and the router would have ignored
  them. `schema.assignments` now describes what a parent is authoritative for,
  and `enroll_accept` and `config_snapshot` validate against it. The generated
  fixture changed with it, and gained a case for an ISP reaching past what it
  owns.
- **Nothing is assigned until the child has proved the whole exchange.**
  `parentEnrollment` now takes the relationship identity up front and calls
  `assign` at the confirm step. A caller that walks away after the challenge
  costs a parent nothing durable — which matters because on a shared channel
  several parents may answer one discovery.
- **A child enrolls with the parent it discovered.** Where two parents share a
  secret, both can answer. The child pins the parent identity from the offer and
  ignores a challenge from anyone else.
- **A parent only advances on the frame it is waiting for.** A sibling's
  `enroll_challenge` carries the same Request ID, and treating it as this
  exchange's next step tore down joins that were going perfectly well. Found by
  the two-router test, and it would have been found in world by two routers in
  range of each other.
- **A failed assignment is answered, a failed proof is not.** Once a caller has
  shown it holds the secret, a duplicate name or an exhausted pool is worth
  saying out loud, because only that caller can read the reply. Before that,
  silence.
- **A Customer Router keeps the identity it earned.** Ticket 8 says the ISP
  assigns a Router identity. A router that has already served a standalone
  Customer Network has one, and its LAN relationships embed it. It therefore
  presents that identity, and the ISP decides whether to accept it — refusing
  with `name_conflict` when another router already holds the name. The ISP stays
  authoritative over its registry without orphaning a working network.
- **Downstream channels are derived, not coordinated.** An ISP's router channels
  start from a base derived from the channel the Central Server gave it, so two
  ISPs in one World cannot hand out the same channel and nobody has to agree on
  anything.
- **Each Customer Router gets its own Operational Channel**, which means a
  parent listens on every channel it has assigned, and reopens all of them after
  a restart.

## Deliberately deferred

- Traffic Events are buffered at each role and handed over by `drainTelemetry`.
  Relaying them upward needs the Gateway, which is Milestone 6.
- The Central Server's Gateway adapter is exercised only through a fake. The
  real WebSocket, `device.register`, Access Tokens, and the dashboard are
  Milestones 6 and 7.
- `topology_snapshot` reports ISPs, routers, and Network Status. Computers
  appear once the Central Server aggregates a child summary, which the Gateway
  work will need anyway.

Milestone 6 is the next implementation gate: the Go External Application and the
Gateway — `craftnetd` over `net/http`, `coder/websocket`, and SQLite, with
verified ancestry and two-minute Access Tokens.
