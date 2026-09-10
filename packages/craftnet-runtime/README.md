# craftnet-runtime

One configured role, running. The only CraftNet package that performs I/O.

```
ccpm install craftnet-runtime
```

**Version 0.1.0 · wire version 1 · depends on `craftnet-protocol` ^0.1.0,
`craftnet-core` ^0.1.0, `networking` ^1.0.0**

## What it hides

The CraftOS event loop, the modem transport and its Logical Interfaces, the
parent and child link lifecycle, durable generation counters, atomic versioned
snapshots with one backup, the secret store, enrollment, heartbeats and
reconnect backoff, effect execution, Traffic Event buffers, the Gateway
WebSocket, and the terse status screen.

```lua
local runtime = dofile("/.ccpm/packages/craftnet-runtime/0.1.0/init.lua")
  .withPackages({ protocol = protocol, core = core })

local role = runtime.new({
  role = "router",
  path = "craftnet/router",
  adapters = { clock = …, storage = …, links = …, screen = … },
})
role:start()
role:run()
```

Everything it touches arrives **injected**. That is what lets a whole World be
driven from tables in a test while still exercising the real state transitions
in `craftnet-core`.

## The loop

```text
pump ──▶ an event from the links adapter ──▶ submit
                                               │
                              engine:handle ──▶ effects
                                               │
                                    perform each one
                                               │
                              its result ──▶ submit again
```

`submit` runs one input and carries out everything it implies, including the
follow-up inputs the effects produce. **The feedback is a separate input rather
than a return value**: the engine decides what a failure means, not the adapter
that hit it.

`tick` advances what time drives — expiring idle flows, re-judging Connectivity
State, sending due heartbeats, retrying a disconnected parent under backoff.
`run` waits only as long as the next deadline, so an idle role costs nothing.

## Adapters

Five seams. Four are required for every role; the Gateway belongs to the Central
Server alone.

| Adapter | Must provide | Real one |
|---|---|---|
| `clock` | `now`, optional `timer` | `adapter_clock` — monotonic milliseconds since start, never a wall clock |
| `storage` | `read`, `write`, `move`, `remove`, `exists` | `adapter_storage` — rooted, so a role cannot write outside its own state area |
| `links` | `send`, `poll`, optional `connect`, `pending` | `newLinks` over any transport |
| `screen` | `render` | `adapter_screen` |
| `gateway` | `send`, and for the real one `tick`, `pending`, `next` | `adapter_gateway` — a CC:Tweaked `http.websocket` client |

`adapter_clock`, `adapter_storage`, `adapter_modem`, `adapter_screen`, and
`adapter_gateway` are the **only files in CraftNet** that name a CC:Tweaked
global, and they load on demand so a test host without those globals can still
use the package.

## Surface

| | |
|---|---|
| `withPackages{protocol, core}` | bind and get the API |
| `new{role, path, adapters, application?, connectivity?}` | one role, running |
| `newLinks{transport}` | sessions over any transport |
| `enroll` | the parent-child exchange every boundary shares |
| `snapshot`, `secrets`, `connectivity`, `screen` | the pieces on their own |
| `adapters.{clock, storage, screen, modem, gateway}` | the real CraftOS ones |
| `limits` | heartbeat 10 s, disconnect 30 s, backoff 1 s to 30 s |

## Durability

**A snapshot is atomic and versioned, with one backup.** A corrupt primary falls
back; two unreadable copies stop the role and say so rather than inventing a
state to continue from.

**A secret never enters a snapshot.** Secrets live in their own file, and durable
state carries a reference — `gateway_credential_ref`, `credential_ref` — never a
value. That is what lets a snapshot be read, relayed, projected, and shown
without anyone having to remember which field was sensitive.

**Generation counters are durable.** They are what make each session's nonce
different from the last. A role that bumps one in memory and restarts sends a
nonce its parent has already seen, is refused as a replay — correctly — and sits
there unable to reconnect, with no error pointing at why. Milestone 8 found that
one with a restart matrix.

On start, everything ephemeral is rebuilt empty: sessions, counters, NAT Flows,
correlation records, diagnostic buffers. **In-flight work fails rather than
resuming.**

## The links adapter

Holds one Authenticated Session per relationship, seals what goes out, opens
what comes in, and turns a frame arriving before any session exists into
whatever the role package installed to handle it.

Two relationships can share a LAN channel, so the frame itself — its
relationship, its session, its MAC — decides whose it is. A frame that
authenticates against no session is offered to the handshake handler and
otherwise **dropped in silence**, because answering would tell a listener on a
shared channel something.

## The Gateway transport

`adapter_gateway` is the Central Server's outbound WebSocket and the only file
in CraftNet that reaches for the HTTP API. It opens with the Gateway Credential
in an `Authorization` header, sends hello, reads welcome, carries frames,
heartbeats an idle session, and reconnects under bounded exponential backoff.

**A socket is not a session.** Until the welcome decodes there is none, and work
offered in that window fails `gateway_unavailable`. **One bad frame is not a
reason to lose a World**: a frame that does not decode is dropped with its reason
recorded, and the session stays up.

CraftOS delivers websocket events through the same queue as modem messages, so
the modem transport **offers** an event it does not recognise to registered
observers — otherwise a role waiting on a modem would discard every one of them.

## Layout

| | |
|---|---|
| `runtime.lua` | the loop, effect execution, telemetry, screen |
| `links.lua` | sessions over a transport |
| `enroll.lua` | the parent-child exchange, both sides |
| `snapshot.lua`, `secrets.lua` | durable state, and secrets kept apart from it |
| `connectivity.lua` | heartbeats, thresholds, Connectivity State, backoff |
| `screen.lua` | what a role's terminal shows |
| `adapter_*.lua` | the CraftOS boundary |

## Read next

[Architecture](../../docs/architecture.md), and
[Contributing](../../docs/contributing.md) for the fakes that stand in for every
adapter here.
