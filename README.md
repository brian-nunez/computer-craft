# CraftNet

CraftNet is an in-world networking simulation for CC:Tweaked. Its Lua packages
model one Central Server, multiple ISPs, Customer Routers, and Computers, while
the Go External Application provides the controlled WebSocket gateway and
operator dashboard.

Implementation Milestone 4 is complete in simulation: an Operator can now build
a Customer Network. `craftnet-router` and `craftnet-computer` add the setup and
join wizards, LAN Password admission, local DNS, and local traffic on top of the
three shared packages. Its in-world acceptance run has not been performed yet —
see [the checklist](docs/implementation/acceptance/milestone-4-in-world.md).
Traffic between Customer Networks intentionally begins in Milestone 5. The
complete design and delivery gates are indexed in
[the CraftNet v1 map](.scratch/craftnet-v1/map.md), and completed-gate evidence
is recorded under [`docs/implementation/`](docs/implementation/).

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

Run the complete Milestone 4 gate from the repository root:

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

## Provisioning a development World

The External Application owns the root secrets. Generate a development World Key
and Gateway Credential before running any CraftOS role, so that nothing in world
invents a root secret or reuses a fixture credential:

```bash
cd external && go run ./cmd/craftnetprov -out ../data/world.json
```

The bundle is written with owner-only permissions and is never overwritten in
place. `data/` is already excluded by `.gitignore`.

## Repository layout

```text
external/                 Go module, craftnetd, and the protocol implementation
packages/                 ccpm Lua packages and immutable manifests
spec/protocol/v1/         cross-language protocol fixture catalog
tests/lua/                portable Lua test runner, support, and suites
scripts/                  local and CI entry points
docs/adr/                 accepted architecture decisions
docs/implementation/      completed-milestone gate evidence
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

`craftnet-router` and `craftnet-computer` are composition roots over those
three. `craftnet-isp` and `craftnet-central` arrive in Milestone 5.

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
