# Deployment posture for v0.1.0

- **Type**: `wayfinder:grilling`
- **Status**: open
- **Assignee**: unclaimed
- **Blocked by**: nothing
- **Map**: [the software half of the v0.1.0 gate](../map.md)

## Question

What does CraftNet claim to support as a deployment, and what does it refuse
to pretend about?

The uncommitted `compose.yaml` publishes `8080:8080` and the Dockerfile serves
`0.0.0.0:8080`, with no TLS and without `-secure-cookies`. `setup.md` documents
the same shape — `craftnetd serve -listen 0.0.0.0:8080`, with TLS as an aside.
So on the documented happy path the dashboard session cookie and the
`Authorization: Bearer <Gateway Credential>` header both cross the network in
clear, while [`docs/protocol/v1.md`](../../protocol/v1.md) says the Gateway
relies on WSS.

The compose file is also stricter than the docs in every other respect —
`read_only`, `no-new-privileges`, a non-root user, cpu and memory limits — so
the plaintext default is the one thing out of step with its own intent.

Options, not exclusive:

1. **Loopback by default, reverse proxy documented.** `craftnetd` keeps its
   `127.0.0.1:8080` default, compose binds `127.0.0.1:8080:8080`, and setup.md
   gains the proxy step. Smallest change; pushes TLS onto the Operator.
2. **TLS in `craftnetd`.** A cert flag pair and `-secure-cookies` implied when
   it is on. Self-contained, and one more thing to get right in a release that
   has not yet been run by anybody.
3. **State the boundary and mean it.** v0.1.0 is supported on a trusted LAN
   only, said plainly in setup.md and the release notes, with the Gateway
   Credential's exposure named as the specific risk.

Whatever wins, `-secure-cookies` and the listen address should agree with it by
default rather than by an Operator remembering.

## Evidence

- `compose.yaml` — `ports: "8080:8080"`, no TLS, no `-secure-cookies`
- `external/Dockerfile` — `CMD ["serve", …, "-listen", "0.0.0.0:8080"]`
- `external/cmd/craftnetd/main.go:74` — the `127.0.0.1:8080` default it overrides
- `docs/operations/setup.md` — step 1, and "Behind TLS, add `-secure-cookies`"
- `docs/protocol/v1.md` — "The Gateway", and the header the credential travels in

## Blocks

[Finish the container and document it](finish-the-container.md) — its binding
and its documentation follow from whatever is decided here.

## Also answer

Does this block the v0.1.0 tag?
