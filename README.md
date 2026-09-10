# CraftNet

CraftNet is an in-world networking simulation for CC:Tweaked. Its Lua packages
model one Central Server, multiple ISPs, Customer Routers, and Computers, while
the Go External Application provides the controlled WebSocket gateway and
operator dashboard.

All nine implementation milestones are built. The automated half of the v1
release gate passes: 294 Lua tests, the Go suite under `-race`, a 1,685-entity
scale simulation over 10,000 seeded operations, a full restart matrix, and a
malformed-input corpus. The gate itself is **not** met — no acceptance run has
been performed in Minecraft. [The acceptance
report](docs/implementation/acceptance/report-v0.1.0.md) says exactly what is
proved and what is not, and this repository stays at `0.1.0-dev` until it is.

[Milestone 9](docs/implementation/milestone-9.md) built the in-world leg of the
external path, which the v1 gate had refused to tag a release without: a
Computer names an External Operation with
[`external_call`](docs/adr/0010-name-the-external-application-with-its-own-message-kind.md),
and the Central Server holds a real `http.websocket` session to `craftnetd`.

**[The documentation index](docs/README.md)** says which document answers which
question. The ones most people want:

| | |
|---|---|
| [Architecture](docs/architecture.md) | how the pieces fit, and what a request actually does |
| [Setup](docs/operations/setup.md) · [Recovery](docs/operations/recovery.md) | building a World, and fixing one |
| [The v1 wire](docs/protocol/v1.md) | the protocol, in prose |
| [`CONTEXT.md`](CONTEXT.md) | what every CraftNet word means, and what not to call it |
| [Contributing](docs/contributing.md) · [`AGENTS.md`](AGENTS.md) | the gate, the test harnesses, and the conventions this repo enforces |

The complete design and delivery gates are indexed in [the CraftNet v1
map](.scratch/craftnet-v1/map.md); milestone evidence is under
[`docs/implementation/`](docs/implementation/), and [the release
notes](docs/releases/v0.1.0.md) state the tested scale and the v1 exclusions.

## Supported development versions

Version pins used by acceptance reports live in [`spec/versions.json`](spec/versions.json):

- Minecraft 1.21.11
- Fabric
- CC:Tweaked 1.117.1
- Go 1.27.0
- CraftNet wire version 1

Lua code must remain compatible with Lua 5.2 as provided by CC:Tweaked. The Lua
test entry point prefers `lua5.2`, then falls back to `lua` or `luajit` for quick
local feedback.

## Development commands

Run the complete release gate from the repository root:

```bash
make test
make fmt-check
```

The individual checks are:

```bash
bash scripts/test-lua.sh
bash scripts/test-fixtures.sh
bash scripts/test-catalog.sh
bash scripts/check-fixtures.sh
bash scripts/test-go.sh
```

`test-go.sh` runs `go test -race ./...` inside `external/`. The fixture command
validates [`spec/protocol/v1/manifest.json`](spec/protocol/v1/manifest.json),
including safe paths, listed JSON files, schema version, wire version, and the
implementations that must replay each fixture. Its Go tests deliberately supply
malformed and unlisted fixtures to verify rejection. The catalog check verifies
that every `registry.json` entry agrees with its local manifest, dependency
names, source files, and immutable GitHub URL, and that no package source ships
without being listed. `check-fixtures.sh` regenerates the protocol catalog and
diffs it, so the generator can never drift away from the checked-in fixtures.

Tests default to deterministic seed `12648430` (`0xC0FFEE`). Reproduce another
seed with:

```bash
CRAFTNET_TEST_SEED=42 make test
```

Lua 5.2 supplies `bit32`, which is the path CC:Tweaked takes. Newer interpreters
removed it, so running the suite under both covers each half of
`packages/craftnet-protocol/files/bitops.lua`:

```bash
LUA_BIN=lua5.2 bash scripts/test-lua.sh
LUA_BIN=lua5.4 bash scripts/test-lua.sh
```

Lua and Go temporary-state helpers create isolated data beneath operating-system
temporary directories. Local credentials, databases, runtime data, build output,
and coverage output are excluded by `.gitignore`; tests must never write them
into the repository.

## The protocol catalog

[`spec/protocol/v1/`](spec/protocol/v1/) is the executable compatibility source
of truth: canonical-JSON goldens, published SHA-256 and HMAC vectors, the key
derivation chain, one body per message kind, authenticated frames, tampering and
replay sequences, limit edges, and the stable error catalog. Lua and Go both
replay it and must classify every case identically.

It is generated, not hand-edited. After changing the generator:

```bash
make fixtures
```

## The role engine

[`packages/craftnet-core/`](packages/craftnet-core/) holds every CraftNet
decision behind one seam:

```lua
local engine = core.newEngine({ role = "router", state = durableState })
local outcome = engine:handle(input, now)
-- outcome = { state_changes, effects, result, revision }
```

An effect is a description, not an action: the runtime performs it and reports
back by feeding the answer in as the next input. Nothing in the package touches
a peripheral, a file, a timer, or a socket, which is what lets the whole of
CraftNet's behavior be tested without Minecraft.

`tests/lua/support/simulator.lua` runs many engines against a fake clock and a
message queue, and `tests/lua/support/reference.lua` stands up the canonical
Home and Farm topology through real state transitions — no address, route, or
binding is written by hand. The acceptance scenarios run against it in
[`tests/lua/core_scenarios_test.lua`](tests/lua/core_scenarios_test.lua).

## Running a role

[`packages/craftnet-runtime/`](packages/craftnet-runtime/) is the only part of
CraftNet that performs I/O. It owns the CraftOS event loop, the link lifecycle,
atomic versioned snapshots with one backup, reconnect backoff, and the terse
status screen. Everything it touches arrives as an injected adapter:

```lua
local instance = runtime.new({
  role = "router",
  path = "state/router",
  adapters = { clock = clock, storage = storage, links = links, screen = screen },
})
instance:start()   -- load the snapshot, or start fresh
instance:run()     -- pump events, execute effects, heartbeat, reconnect
```

An effect the engine asks for is carried out and its result fed back in as the
next input, so a failed write or a failed send reaches the authority that cared
about it rather than vanishing inside an adapter.

`tests/lua/support/fakes.lua` supplies storage, clock, links, screen, and
gateway adapters that a test can corrupt, fail, or freeze at will.

## Building a Customer Network

On the Computer that will be the router:

```text
ccpm install craftnet-router
```

Then run the package's `setup` program. It asks for the network name, the
router's own address, the pool to hand out, the LAN channel, and a LAN Password,
checking each answer as it is typed. Start it with `startup`.

On each Computer that will join:

```text
ccpm install craftnet-computer
```

Run `setup`, give it a hostname and the LAN Password, and it comes back with its
address, its default gateway, and its DNS. The password is used exactly once:
what is kept is a LAN Credential unique to that Computer, which can be revoked
on its own and which is what every later reconnect uses.

## Building the whole World

Provision the World in the External Application, then carry the values in. They
are shown exactly once: afterwards the application holds only digests.

```bash
cd external
go run ./cmd/craftnetd provision -world world-overworld -central central-main
go run ./cmd/craftnetd serve
```

| Computer | Install | Then run |
|---|---|---|
| Central Server | `ccpm install craftnet-central` | `setup`, then `token` |
| ISP | `ccpm install craftnet-isp` | `setup` with that token, then `token` |
| Customer Router | `ccpm install craftnet-router` | `setup`, then `uplink` with that token |
| Computer | `ccpm install craftnet-computer` | `setup` with the LAN Password |

Each token is one-time and 16 characters in four groups, short enough to read
off one screen and type into another. A parent stores no token — only which
counters it has spent.

A Customer Network works perfectly well without an ISP. `uplink` is what makes
it reachable from another one.

Once it is up, a router has `expose HOSTNAME SERVICE` (nothing is reachable from
another network until it does) and `revoke HOSTNAME`. Every Computer has
`craftnet status`, `craftnet resolve NAME`, and `craftnet call NAME SERVICE` —
and `craftnet call api.craft OPERATION`, which is the External Application.

[The setup guide](docs/operations/setup.md) is the whole procedure in order, and
[the recovery guide](docs/operations/recovery.md) is organised by what you will
actually see when something breaks.

## The External Application

[`external/`](external/) is one Go binary: `craftnetd`. It serves the Central
Server's Gateway, the embedded Operator dashboard, and the dashboard API, on one
origin and out of one SQLite file.

```bash
cd external
go run ./cmd/craftnetd provision -world world-overworld -central central-main
go run ./cmd/craftnetd operator -name alex          # reads the password from stdin
go run ./cmd/craftnetd serve -listen 127.0.0.1:8080
```

A World Key, a Gateway Credential, and a Device Credential are stored as
digests only, so a database that leaks tells an attacker nothing it can present.
An Access Token is an Ed25519 JWT that lives two minutes and is checked against
the exact CraftNet ancestry it arrived on: a valid token presented from another
Customer Network is refused.

Which External Operations exist is an allowlist, and adding one is a handler
plus a policy at the composition root — never a new route, a new session, or a
proxy to an arbitrary URL. This release allows `device.register`, `token.issue`,
`echo`, `time.now`, and `test.identity`.

The Central Server reaches it over CC:Tweaked's `http.websocket`, which has to
be enabled and allowed for that host — see [the setup
guide](docs/operations/setup.md#let-the-central-server-reach-it). When it is not
reachable, external calls give `gateway_unavailable` and everything inside the
World carries on.

`data/` is excluded by `.gitignore`.

## The dashboard

Open the address `craftnetd serve` prints. The page, its assets, and its API are
all on that one origin, so the session is an `HttpOnly`, `SameSite=Strict`
cookie rather than a token in local storage — and there is nothing to fetch from
a CDN, so it works next to a Minecraft server with no internet.

Three views share one selection. **Topology** is primary: the World as a
hierarchy, with each ISP's Provider Allocation, each Customer Network's Provider
Address and Network Status, and each Computer's network-scoped address — so the
two Computers that both hold `192.168.1.20` are visibly in different Customer
Networks. **Traffic** is the dense event table with filters and counters, and
**Incidents** is the exception queue and its timeline. Selecting a node in
Topology and pressing "See its traffic" carries that selection across.

A credential's *status* is shown; a credential's *value* never is. Neither is a
payload, a token, or a MAC — a Traffic Event was never allowed to carry one.

Disabling a Customer Network asks for confirmation, records the decision against
the Operator who made it, and sends one idempotent Command to the Central
Server. Disabling refuses that network's new operations and keeps every durable
registration, so re-enabling it needs no re-enrollment and changes no address.

```bash
go run ./cmd/craftnetd operator -name alex        # create or re-password
go run ./cmd/craftnetd operator -list
go run ./cmd/craftnetd operator -name alex -disable
go run ./cmd/craftnetd serve -secure-cookies      # behind TLS
```

A World nobody is connected to is marked stale rather than shown as current:
what the dashboard displays is the last thing a Central Server reported, and it
says so.

## Repository layout

```text
external/                 Go module, craftnetd, and the protocol implementation
packages/                 ccpm Lua packages and immutable manifests
                          each has a README describing what it hides
spec/protocol/v1/         cross-language protocol fixture catalog
tests/lua/                portable Lua test runner, support, and suites
scripts/                  local and CI entry points
AGENTS.md                 conventions this repo enforces
CONTEXT.md                the domain vocabulary
docs/architecture.md      how the pieces fit today
docs/contributing.md      the gate, the test harnesses, extension points
docs/protocol/v1.md       the v1 wire in prose
docs/adr/                 accepted architecture decisions
docs/operations/          setup and recovery, for whoever runs it
docs/releases/            release notes
docs/implementation/      milestone gate evidence and acceptance reports
.scratch/craftnet-v1/     resolved design and delivery tickets
```

`craftnet-protocol` implements the v1 wire: canonical JSON, SHA-256 and HMAC in
pure Lua, key derivation, strict schemas, the session handshake, counters and
replay rejection, framing, correlation, size limits, and timeouts. A caller opens
an enrolled link and exchanges semantic messages; it never calculates a MAC or a
canonical form.

```lua
local protocol = dofile("/.ccpm/packages/craftnet-protocol/0.1.0/init.lua")

-- `session` comes from the enrollment or reconnect handshake; `transport` and
-- `clock` are supplied by craftnet-runtime in Milestone 3.
local link = protocol.open({ session = session, transport = transport, clock = clock })
local result, code = link:request("dns_query",
  protocol.object({ name = "harvester.farm.acme.craft" }))
```

`craftnet-core` turns validated input into state changes and effects for the
Central Server, ISP, Customer Router, and Computer roles. It is pure: a
composition root injects the protocol package with `core.withProtocol()`, and
the engine performs no I/O of its own.

```lua
local core = dofile("/.ccpm/packages/craftnet-core/0.1.0/init.lua").withProtocol(protocol)
local engine = core.newEngine({ role = "router", state = saved })
```

`craftnet-runtime` runs one configured role: the CraftOS event loop, the modem
transport over the `networking` package, the session-carrying links adapter,
durable snapshots, a separate secret store, Connectivity State, and reconnect
backoff.

```lua
local runtime = dofile("/.ccpm/packages/craftnet-runtime/0.1.0/init.lua")
  .withPackages({ protocol = protocol, core = core })
```

`craftnet-central`, `craftnet-isp`, `craftnet-router`, and `craftnet-computer`
are composition roots over those three. Each wires them together and supplies
only what is genuinely its own; none carries a second implementation of
protocol, persistence, or routing.

## ccpm

A small GitHub-backed package manager for CC:Tweaked. It resolves recursive
dependencies, chooses the newest compatible semantic version, detects cycles,
downloads files before installation, and records installed versions in a lock file.

## Publish it

1. Add the file URLs and manifests for your real packages.
2. Push the repository to GitHub and install ccpm on a CC:Tweaked computer:

```text
wget https://raw.githubusercontent.com/brian-nunez/computer-craft/main/ccpm.lua ccpm.lua
```

## Use it

```text
ccpm install networking
ccpm install peripheral-discovery ^1.0.0
ccpm install craftnet-router
ccpm install craftnet-computer
ccpm list
```

Packages are stored under `/.ccpm/packages/<name>/<version>/`. Application code
can load a known locked package path, or a future ccpm release can add shims and a
`require` searcher. The lock file is `/.ccpm/lock.json`.

The `networking` package automatically installs `peripheral-discovery`. Load it
from its locked package path, then select a modem:

```lua
local networking = dofile("/.ccpm/packages/networking/1.0.0/init.lua")
local selected = networking.selectModem({
  -- CC:Tweaked reports both normal and Ender modems as wireless. Identify an
  -- Ender modem by its attached side/name when the server exposes no subtype.
  kinds = { left = "ender" },
})

if selected then
  print(selected.name, selected.kind)
  selected.wrapped.open(1234)
end

for _, monitor in ipairs(networking.monitors()) do
  print("monitor", monitor.name)
end
```

Modem selection is deterministic: Ender first, then wired, then ordinary
wireless; ties are sorted by peripheral name. The discovery package also offers
`scan`, `findAll`, `modems`, `monitors`, and `watch`.

Supported constraints are `*`, exact versions, `^`, `~`, `>=`, `>`, `<=`, and `<`.
This MVP accepts one constraint per dependency; compound ranges are not supported.
