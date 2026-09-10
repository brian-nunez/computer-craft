# Milestone 3 — Runtime, persistence, and recovery

Status: complete on 2026-09-09.

Milestone 3 implements `craftnet-runtime`: the only part of CraftNet that
performs I/O. It loads durable state, feeds inputs to the engine, carries out
the effects the engine asks for, and reports each result back as the next
input — which is what keeps a failed write or a failed send visible to the
authority that cared about it, instead of disappearing inside an adapter.

## Delivered

### `craftnet-runtime`

| Module | Owns |
|---|---|
| `runtime` | The event loop, effect execution, effect-result feedback, heartbeats, reconnect scheduling, telemetry hand-off |
| `snapshot` | Versioned atomic snapshots, one backup, digest verification, corrupt-primary recovery |
| `connectivity` | Connectivity State from silence, heartbeat scheduling, bounded exponential backoff |
| `screen` | The terse local status lines |
| `adapter_storage` | CraftOS `fs`, rooted so a role cannot write outside its own state |
| `adapter_clock` | Monotonic milliseconds and CraftOS timers |
| `adapter_screen` | Terminal drawing |
| `adapter_modem` | Modem selection through `networking`, sealed frames on operational channels, `modem_message` translation |

A runtime is handed every adapter it uses, so a whole World can be driven from
tables while still exercising the real state transitions in `craftnet-core`.

### Additions to `craftnet-core`

Two transitions were added, because both belong to the engine rather than the
runtime:

- **`effect_result`** — the runtime reports what happened when it carried out an
  effect. A send that never left drops the correlation it belonged to rather
  than retrying; CraftNet never replays an ordinary request on its own.
- **Reconciliation** — `reconcile`, `config_request`, and `config_snapshot`. A
  child presents the last parent revision it accepted; the parent answers with
  an acknowledgement when nothing changed, or a full replacement when it did.

### Fake adapters

`tests/lua/support/fakes.lua` supplies storage, clock, links, screen, and
gateway. They are deliberately hostile: a test can corrupt a snapshot, tamper
with one so it still parses, fail every write, fail a send, drop a link, or move
time by an exact number of milliseconds.

## Gate evidence

The Lua suite runs 158 tests.

| Gate requirement | Evidence |
|---|---|
| Restart preserves every durable field | `runtime_lifecycle_test.lua` — identities, network identity, pool, Provider Address, Address Bindings, Exposed Services, and revision all survive |
| Restart discards every ephemeral field | same file — no NAT Flow, correlation record, session, or diagnostic buffer survives, and the words `flow`, `transit`, `session`, and `counter` never appear in a snapshot |
| A corrupt primary loads its valid backup | `runtime_snapshot_test.lua` — truncation and digest-detected tampering both fall back; both copies corrupt is reported rather than papered over |
| Reconciliation obeys authority ownership | `runtime_lifecycle_test.lua` — the ISP's Provider Address is accepted, and its attempt to move the router's own address, pool, and LAN channel is not |
| Connectivity State changes at the specified thresholds | `runtime_connectivity_test.lua` — ready under 10s, degraded at 10s, disconnected at 30s, revoked terminal |
| Pending ordinary requests are not replayed | `runtime_lifecycle_test.lua` — a restart sends nothing, and neither does a tick |
| Buffers remain at 100/500/2,000 | `runtime_lifecycle_test.lua` and `core_units_test.lua` — the router's buffer holds exactly its capacity and counts the overflow |
| Core modules perform no filesystem, modem, timer, HTTP, or screen I/O | `core_purity_test.lua` — see below |

### The purity test

The gate item that matters most is checked twice.

First by reading the source: every behavioural module in `craftnet-core` and
`craftnet-protocol` is scanned for `fs`, `io`, `http`, `peripheral`, `term`,
`textutils`, `shell`, `os.*`, `loadfile`, `dofile`, and `require`. Only each
package's `init.lua` may load a file, only once, and only from its own module
directory.

Then by running: every behavioural core module is loaded into an environment
where each of those globals is a trap that raises, and the whole reference
topology is stood up inside it — addressing, DNS resolution across the World, a
cross-network request with paired NAT Flows, and an `inbound_denied` refusal.
A deliberately impure canary module proves the sandbox would actually notice.

Interpreter and seed coverage:

```text
LUA_BIN=lua5.2 CRAFTNET_TEST_SEED=12648430 bash scripts/test-lua.sh
LUA_BIN=lua5.2 CRAFTNET_TEST_SEED=42       bash scripts/test-lua.sh
LUA_BIN=lua5.4 CRAFTNET_TEST_SEED=42       bash scripts/test-lua.sh
LUA_BIN=luajit CRAFTNET_TEST_SEED=7        bash scripts/test-lua.sh
make fmt-check && make test
```

LuaJIT matters here beyond portability: it takes the `setfenv` branch of the
purity sandbox, where the newer interpreters take the `loadfile` environment
argument. Both paths trap.

## Decisions made inside this milestone

- **Connectivity State lives in the runtime, not the core.** It is a judgement
  about silence, which means it is a judgement about time and I/O. Keeping it
  out of the engine is what lets the engine stay pure.
- **`degraded` is one missed heartbeat.** Ticket 11 fixes ten seconds and thirty
  but does not say where `degraded` sits between them. It is now the band from
  the heartbeat interval to the disconnect threshold: long enough to be worth
  showing, short enough not to be a loss.
- **A snapshot carries a digest.** Ticket 11 requires recovery from a corrupt
  primary. Truncation is easy to spot, but a snapshot edited to still parse is
  not — without a digest a router would silently load someone else's address.
- **Both copies corrupt refuses to start.** v1 does not invent a state to
  continue from, and it does not overwrite the unreadable files, so an Operator
  can still recover them by hand.
- **A relationship is observed on the submit path, not the poll path.** A
  relationship is just as real when a setup wizard hands it over as when a modem
  event brings it in, so the runtime watches every input rather than only polled
  ones.
- **Only the parent relationship is retried.** A child reconnects to its own
  parent, so a role waits to be found again rather than chasing every Computer
  that went quiet. Being told twice that a relationship is down does not push
  the next attempt further out.
- **An ISP stores what a router declared, and owns none of it.** Reconciliation
  needs the ISP to send a complete router configuration, so a registering router
  declares its LAN fields. The router applies only the four fields the ISP is
  authoritative for and ignores the rest — ownership is enforced at the
  receiver, which is where it can actually be checked.
- **`networking` moved from `craftnet-protocol` to `craftnet-runtime`.**
  Milestone 1 flagged this edge as misplaced and deferred it to the milestone
  where the runtime would actually wire a modem. That is this one.

## Deliberately deferred

- `adapter_modem` carries relationships that already exist. First enrollment —
  discovery, the one-time token or LAN Password, and the credential that comes
  out of it — belongs to the role packages and their setup wizards, so the
  adapter takes an injected handshake through `installHandshake`. Its in-world
  verification is Milestone 4's gate.
- The 10-second in-world request deadline is already implemented in
  `craftnet-protocol`'s link, which the modem adapter drives. The runtime does
  not duplicate it.
- Traffic Events are buffered and handed over by `drainTelemetry`. Batching them
  upstream needs the Gateway that Milestone 6 builds, so nothing relays yet.
- The Central Server's `gateway` adapter interface exists and is exercised only
  through a fake; the real WebSocket is Milestone 6.

Milestone 4 is the next implementation gate: the local Customer Network vertical
slice — `craftnet-computer` and `craftnet-router`, the setup and join wizards,
LAN Password challenge-response, and the first traffic on a real in-world LAN.
