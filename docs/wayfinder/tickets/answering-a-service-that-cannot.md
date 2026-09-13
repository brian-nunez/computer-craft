# What a Computer answers when a service cannot

- **Type**: `wayfinder:grilling`
- **Status**: open
- **Assignee**: unclaimed
- **Blocked by**: nothing
- **Map**: [the software half of the v0.1.0 gate](../map.md)

## Question

`Runtime:performDeliver` returns `nil` in two cases, and in both the caller
hears nothing at all until its own deadline passes:

- The application has no handler for the Exposed Service that was asked for.
- The handler raised. `pcall` fails, `internal_error` is recorded into
  `self.lastError`, and the Computer keeps it.

The second is the worse one: the Computer knows exactly what happened and does
not say. [`AGENTS.md`](../../../AGENTS.md) lists this under rules with teeth —
*"Answer, never hang. A failure a peer is waiting on travels back as a stable
code. Silence until timeout is a defect, not a fallback."*

This is reachable in ordinary operation. `expose harvester harvester.status` on
the Customer Router is a separate act from the Computer's program registering
that handler, so the two drift apart whenever a program is edited or restarted.

What travels back? The catalog has no code for *no such service*:

- `inbound_denied` is the Customer Router's refusal — no matching Exposed
  Service permits the request. Reusing it would make two different refusals,
  at two different layers, indistinguishable to the caller.
- `internal_error` fits the raise honestly and fits the missing handler badly.
- A new code is a wire constant, and wire constants change by ADR.

Decide the code, then decide whether both cases share it.

## Evidence

- `packages/craftnet-runtime/files/runtime.lua:237` — `performDeliver`, both `nil` returns
- `packages/craftnet-core/files/engine.lua:245` — `transit:expire`, which emits an
  ephemeral `transit_expired` locally and sends nothing back
- `docs/protocol/v1.md` — the error catalog
- `AGENTS.md` — "Rules with teeth"

## Also answer

Does this block the v0.1.0 tag?
