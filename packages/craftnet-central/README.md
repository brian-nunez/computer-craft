# craftnet-central

The Central Server: world infrastructure, and the World's one way out.

```
ccpm install craftnet-central
```

**Version 0.1.0 · wire version 1 · depends on `craftnet-runtime` ^0.1.0**

## What it is

One per World. It owns the World identity, the ISP registry, the world-wide RFC
6598 allocator, the exact route directory, and Customer Network Status — and it
holds the single WebSocket to the External Application.

**It is not an ISP.** It is infrastructure every ISP shares, and mistaking the
two is the error [ADR 0001](../../docs/adr/0001-separate-world-coordination-from-isps.md)
exists to prevent.

Every ISP reaches every other ISP through it and only through it. Its route map
holds **one exact entry per Customer Network** — no routing protocol and no
prefix matching, because a range here organises allocation, not delivery
([ADR 0007](../../docs/adr/0007-centralize-interconnection-with-exact-route-registrations.md)).

## Programs

| | |
|---|---|
| `setup` | apply the provisioning bundle from `craftnetd provision` |
| `token` | issue an ISP Enrollment Token, or show the ones still outstanding |
| `startup` | run it |

Its root secrets come from outside Minecraft. `craftnetd provision` prints a
World Key and a Gateway Credential **once**, and `setup` takes them; nothing in
world invents either. The World Key derives ISP Enrollment Tokens, and what
reaches durable state is a **reference** to each secret, never a value.

An Operator carries a token from this screen to an ISP's. It is spent on use,
and reissuable if the screen is lost — see
[`craftnet-protocol`](../craftnet-protocol/README.md#tokens).

## Channels

| | |
|---|---|
| 42000 | where ISPs discover it |
| 42100+ | one operational channel per admitted ISP |

## Surface

`new{path, adapters, discovery_channel?, gateway_factory?}` returns a Central
Server.

| | |
|---|---|
| `start`, `run`, `serve`, `tick`, `stop` | lifecycle |
| `provision(bundle)` | apply a `craftnetd provision` bundle |
| `issueToken`, `outstanding` | ISP Enrollment Tokens |
| `setNetworkStatus(id, status, commandId)` | the one administrative command |
| `topology` | the projection the External Application receives |
| `receiveGateway(kind, body, correlation)` | a frame from the External Application |
| `gatewayStatus`, `publishTopology`, `publishTraffic` | the Gateway Session |
| `state`, `lines` | authoritative state, and what the screen shows |

`wizard` holds the setup questions and their validation, separately from the
asking, so both are testable.

## The Gateway

One outbound WebSocket per World, opened by this role and no other
([ADR 0008](../../docs/adr/0008-use-one-semantic-gateway-session-per-world.md)).
Connecting is the loop's job, under backoff — the External Application not
running is an ordinary condition, not a reason a Central Server cannot start.

When a session opens, the whole topology goes first, so the External Application
never places a Traffic Event against a World it has not been shown. Then Traffic
Events follow in batches of 100 with durable, strictly increasing sequences: a
batch lost to a disconnect appears at the far end as a **gap in the record**
rather than a plausible present. Up to 2,000 events wait for a session that is
not there, and past that the oldest are dropped — a stopped External Application
costs a fixed amount of memory, not a growing one.

Inward, the Gateway carries an answer to an External Operation this World asked
for, and one administrative command: `set_network_status`. That is the whole of
the External Application's authority. It never edits a World; it asks, and the
answer is applied here, on authoritative state, through the same handler an
Operator at this terminal reaches — including its idempotency by Command ID.

A World provisioned without a Gateway URL simply has none. Addressing, names,
routing, NAT, and Network Status all carry on
([ADR 0002](../../docs/adr/0002-keep-network-authority-in-world.md)); external
calls fail `gateway_unavailable`.

## Layout

`central.lua` is the composition root; `wizard.lua` the setup questions;
`bootstrap.lua` finds the installed packages through the `ccpm` lock file.
`setup.lua`, `token.lua`, and `startup.lua` are the programs.

## Read next

[Setup](../../docs/operations/setup.md) ·
[Recovery](../../docs/operations/recovery.md) ·
[Architecture](../../docs/architecture.md)
