# Prune expired dashboard sessions

- **Type**: `wayfinder:task`
- **Status**: open
- **Assignee**: unclaimed
- **Blocked by**: nothing
- **Map**: [the software half of the v0.1.0 gate](../map.md)

## What is wrong

`identity.PruneSessions` is written and has no production caller.
`App.PruneDaily` reaches only `View.Prune`, which prunes Traffic Events and
nothing else, so expired dashboard sessions accumulate in the `sessions` table
for the life of the database.

Small, but it is a table that only grows, in the one file an Operator is told
to keep.

## Carry the fix

Nothing to decide. Retention already runs daily and already refuses to touch
audit records; expired sessions belong in the same sweep.

- Call `PruneSessions` from the same daily pass, beside the event prune.
- Keep the existing rule intact: pruning telemetry must not prune the record of
  a decision. Sessions are neither, so they simply join the sweep.
- Report what it removed the way the event prune does, so an Operator reading
  the log sees both numbers.
- Land it with a regression test that fails without it.
  `dashboard_test.go:287` already drives `tx.PruneSessions` directly and shows
  the fixture to build on.

## Evidence

- `external/internal/identity/operator.go:217` — `PruneSessions`, no caller
- `external/internal/app/app.go` — `Prune` and `PruneDaily`, events only
- `external/internal/worldview/worldview.go:198` — `Prune`, `PruneEvents` alone
- `external/cmd/craftnetd/main.go:96` — where the daily pass is started
