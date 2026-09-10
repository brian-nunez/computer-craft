# craftnet-isp

An ISP: the middle of CraftNet, and the only path a Customer Network has out.

```
ccpm install craftnet-isp
```

**Version 0.1.0 · wire version 1 · depends on `craftnet-runtime` ^0.1.0**

## What it is

An independently operated provider connecting any number of Customer Routers to
CraftNet through the Central Server. A World may hold any number of them; the
reference topology has one, called Acme.

It owns its **Provider Allocation** — a block of RFC 6598 space the Central
Server delegated to it, overlapping no other ISP's — the Provider Address each
of its Customer Routers holds, and the route registrations it publishes upward
on their behalf.

What it does not own is the traffic. An ISP forwards and checks; it does not
decide where a Customer Network is. That is the Central Server's route
directory, and an ISP reaches another ISP's networks only through it — even for
two networks it serves itself.

## Programs

| | |
|---|---|
| `setup` | enroll upstream with an ISP Enrollment Token from the Central Server |
| `token` | issue a Router Enrollment Token, or show the outstanding ones |
| `startup` | run it |

An Operator carries a token from the Central Server's screen to this one, then
carries one from here to each Customer Router. Each is spent on use.

## Channels

| | |
|---|---|
| 42000 | where it finds the Central Server |
| 42001 | where its Customer Routers discover it |
| 43000, +100 each | one operational channel per admitted router |

Upstream is an Ender modem — the Central Server is across the World. Downstream
may be whatever reaches the routers it serves.

## Surface

`new{path, adapters, …}` returns an ISP.

| | |
|---|---|
| `start`, `run`, `serve`, `tick` | lifecycle |
| `configure(settings)` | apply the wizard's answers |
| `enrollUpstream`, `connectUpstream`, `establish` | joining and rejoining the Central Server |
| `issueToken`, `outstanding` | Router Enrollment Tokens |
| `allocationsFrom`, `downstreamBase` | its delegated space and channel base |
| `state`, `lines` | authoritative state, and what the screen shows |

## What it checks

An ISP is a boundary, and it enforces exactly what a boundary can know:

- **A Customer Router may speak only for its own Customer Network.** A router
  claiming another network's identity in a `source` is refused
  `forbidden_operation` — this is where that stops.
- **A Provider Address must fall inside this ISP's own allocation**, or the
  Central Server refuses the route registration.
- **Nothing travels downward that should not.** An `external_call` arriving from
  the Central Server is `inbound_denied`: the External Application observes a
  World, it does not call into one.

It refuses rather than queues. When the next relationship is at its bound, the
answer is `busy` — an ISP that queued would turn one slow router into a growing
backlog for every Customer Network it serves.

Its rolling Traffic Event buffer holds 500.

## Layout

`isp.lua` is the composition root; `wizard.lua` the setup questions;
`bootstrap.lua` finds the installed packages. `setup.lua`, `token.lua`, and
`startup.lua` are the programs.

## Read next

[Setup](../../docs/operations/setup.md) ·
[Architecture](../../docs/architecture.md) ·
[ADR 0007](../../docs/adr/0007-centralize-interconnection-with-exact-route-registrations.md)
