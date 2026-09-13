# Upstream Traffic Event relay — ship or hold

- **Type**: `wayfinder:grilling`
- **Status**: open
- **Assignee**: unclaimed
- **Blocked by**: nothing
- **Map**: [the software half of the v0.1.0 gate](../map.md)

## Question

A Customer Router and an ISP each record their own Traffic Events. Nothing
carries them to the Central Server. `traffic_batch` sits in the operational
transport for exactly this and only `central.lua` ever sends one — over the
Gateway, carrying the Central Server's own view.

So the traffic an Operator sees is the Central Server's view of the World, and
scenario 9 will show that rather than a Customer Router's. Whether that is a
release worth tagging is a decision, and
[`report-v0.1.0.md`](../../implementation/acceptance/report-v0.1.0.md) already
says it belongs to whoever owns the release:

> Decide whether shipping v0.1.0 without upstream Traffic Event relay is
> acceptable, or hold the tag for it.

[`milestone-9.md`](../../implementation/milestone-9.md) left it deliberately —
*"a gap no ticket settles and the acceptance report does not name; it wants
deciding, not improvising"* — which is why it is on this map rather than in
somebody's implementation session.

What the decision needs to weigh: a subordinate role relaying upstream means
bounded buffers at two more layers, a sequence space per relationship, and the
same spent-sequence rule Milestone 6 settled from the other side. That is not a
small addition to a release that has never run in world.

## Evidence

- `packages/craftnet-central/files/central.lua:234` — the only `traffic_batch` sender
- `packages/craftnet-protocol/files/schema.lua:506` — the shape, carried by the
  operational transport and unused there
- `docs/implementation/milestone-9.md` — "What is not met, and why"
- `docs/implementation/acceptance/report-v0.1.0.md` — gate item 1

## Also answer

This ticket *is* the ship-or-hold call, so it answers the v0.1.0 question
directly rather than as an afterthought.
