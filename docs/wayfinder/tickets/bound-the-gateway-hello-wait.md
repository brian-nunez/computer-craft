# Bound the Gateway hello wait

- **Type**: `wayfinder:task`
- **Status**: open
- **Assignee**: unclaimed
- **Blocked by**: nothing
- **Map**: [the software half of the v0.1.0 gate](../map.md)

## What is wrong

`Registry.Accept` reads the hello **before** it authenticates, and `readHello`
waits on `conn.Receive(ctx)` with the request context and no deadline. So an
unauthenticated caller can open `/gateway` with any bearer string, send
nothing, and hold a goroutine and a socket for as long as it likes. Nothing
bounds how many do it at once.

`web.go:151` claims the opposite — *"Authentication happens before anything is
read from the socket beyond the opening frame"* — and the unbounded wait **is**
that read. The comment needs correcting alongside the code.

## Confirmed

Dialling `/gateway` with `Bearer not-a-real-credential` and sending nothing:

```
HELD OPEN: server never timed out an unauthenticated silent socket
           (failed to get reader: context deadline exceeded)
```

## Carry the fix

There is nothing to decide about whether a handshake should be bounded, which
is why this ticket carries its own fix rather than a question.

- Bound the wait for the hello. Ten seconds matches the
  `ReadHeaderTimeout` already on the `http.Server`, and reusing that number
  keeps one answer to "how long may an unauthenticated caller hold a slot".
- Close the socket with the same terse policy-violation reason the refusal path
  already uses; a caller that failed learns only that it failed.
- Land it with a regression test that fails without it. The probe above is the
  shape: dial, send nothing, assert the server closes first.

While in here, consider — but do not silently adopt — a read deadline on the
**live** session too. Nothing currently notices a half-open TCP connection, and
`StaleAfter` only changes what the dashboard displays. If that turns out to
want its own decision, raise it rather than folding it in.

## Evidence

- `external/internal/gateway/gateway.go:134` — `Accept`, hello before authentication
- `external/internal/gateway/gateway.go:223` — `readHello`, no deadline
- `external/internal/web/web.go:151` — the comment that says otherwise
- `external/internal/web/web.go:178` — where the request context is handed in
