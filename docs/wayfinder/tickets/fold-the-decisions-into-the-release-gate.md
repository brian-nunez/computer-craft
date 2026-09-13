# Fold the decisions into the release gate

- **Type**: `wayfinder:task`
- **Status**: open
- **Assignee**: unclaimed
- **Blocked by**: every other ticket on this map
- **Map**: [the software half of the v0.1.0 gate](../map.md)

## What this is for

Each ticket on this map answers two things: what CraftNet should do, and
whether it blocks the v0.1.0 tag. This one collects the second answers and puts
them where a release is actually measured, so the software half of the gate
reads as a set of decisions rather than a set of findings.

It is last on purpose. It cannot be taken up until every other ticket is
closed, and it is the ticket that makes the map's destination true.

## Carry the work

- Update
  [`report-v0.1.0.md`](../../implementation/acceptance/report-v0.1.0.md): the
  "What is not proved" and "What has to happen before v0.1.0 is tagged"
  sections both predate this map. Gate item 1 — the upstream Traffic Event
  relay ship-or-hold — is answered by its own ticket and should stop being an
  open question in the report.
- Record what was found and what was decided as an implementation record, in
  the house style: what it delivered **and what it did not prove**. The map's
  Decisions-so-far is the index; the record is the prose.
- Write an ADR for any decision that shapes later work — `AGENTS.md` is the
  test, not a hunch.
- Leave the manual runs exactly as they are. They are
  [out of scope](../map.md#out-of-scope) for this map and still owed.

## Note on this map's own artifacts

`docs/wayfinder/` is a live map, not dated history. When this ticket closes,
decide whether it stays, is archived beside the milestone records, or is
deleted with its content folded into the implementation record. The repo's
documentation index has a place for each of those and no place for a map that
has arrived.
