# Gateway Session concurrency

- **Type**: `wayfinder:grilling`
- **Status**: open
- **Assignee**: unclaimed
- **Blocked by**: nothing
- **Map**: [the software half of the v0.1.0 gate](../map.md)

## Question

`Session.Serve` handles every frame inline, so one External Operation occupies
the whole Gateway Session until its handler returns. Should it keep doing that?

Three shapes, and the trade-off is real in each direction:

1. **Leave it synchronous** and make the constraint explicit — an External
   Operation handler must return promptly, said in `operations/operations.go`
   and enforced by nothing. Cheapest, honest about what the current allowlist
   is, and wrong the first time somebody adds the adapter that package already
   anticipates.
2. **A goroutine per External Operation**, with the existing in-flight bound
   extended to cover them. Ordering between an `external_response` and a
   `topology_snapshot` becomes observable, and `ADR 0008` says one semantic
   Gateway Session per World — this does not break that, but it does mean the
   session is no longer one sequence.
3. **A bounded worker pool** in front of `serveExternalRequest` only. Ingestion
   and command settlement stay on the read loop and stay ordered; only external
   calls run alongside. More moving parts, but the ordering question stays
   confined to the one path that does not need ordering.

Whichever wins, decide what `busy` means afterwards. Today `MaxInFlight` is
only consulted in `deliverCommand`, so the 256 the acceptance report cites
bounds administrative commands and nothing else.

## Evidence

Confirmed by probe, not by reading. Registering a handler that blocks, sending
one `external_request`, then a `topology_snapshot` behind it:

```
BLOCKED: the topology ack never arrived while one handler was busy
```

While one call is in flight, that World's topology ingest, Traffic Event
ingest, heartbeats and `command_result` settlement all queue behind it, and
`lastSeen` stops advancing — so the dashboard marks the World stale after the
30 seconds `gateway.StaleAfter` allows.

- `external/internal/gateway/gateway.go:277` — `Serve`, the whole inbound path
- `external/internal/gateway/gateway.go:318` — `dispatch`, the `external_request` arm
- `external/internal/gateway/ingest.go:144` — `serveExternalRequest`, inline
- `external/internal/gateway/ingest.go` — `deliverCommand`, the only consulter of `inFlight`
- `external/internal/operations/operations.go:1` — "an adapter to a local model
  or another real application lives behind a handler and stops there"

## Also answer

Does this block the v0.1.0 tag?
