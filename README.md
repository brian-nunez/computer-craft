# CraftNet

CraftNet is an in-world networking simulation for CC:Tweaked. Its Lua packages
model one Central Server, multiple ISPs, Customer Routers, and Computers, while
the Go External Application provides the controlled WebSocket gateway and
operator dashboard.

Implementation Milestone 0 is complete: the reproducible test, fixture, package,
and application skeleton is present. CraftNet networking behavior intentionally
begins in Milestone 1. The complete design and delivery gates are indexed in
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

Run the complete Milestone 0 gate from the repository root:

```bash
make test
make fmt-check
```

The individual checks are:

```bash
bash scripts/test-lua.sh
bash scripts/test-fixtures.sh
bash scripts/test-catalog.sh
bash scripts/test-go.sh
```

`test-go.sh` runs `go test -race ./...` inside `external/`. The fixture command
validates [`spec/protocol/v1/manifest.json`](spec/protocol/v1/manifest.json),
including safe paths, listed JSON files, schema version, and wire version. Its Go
tests deliberately supply malformed and unlisted fixtures to verify rejection.
The catalog check verifies that every `registry.json` entry agrees with its local
manifest, dependency names, source files, and immutable GitHub URL.

Tests default to deterministic seed `12648430` (`0xC0FFEE`). Reproduce another
seed with:

```bash
CRAFTNET_TEST_SEED=42 make test
```

Lua and Go temporary-state helpers create isolated data beneath operating-system
temporary directories. Local credentials, databases, runtime data, build output,
and coverage output are excluded by `.gitignore`; tests must never write them
into the repository.

## Repository layout

```text
external/                 Go module and craftnetd composition root
packages/                 ccpm Lua packages and immutable manifests
spec/protocol/v1/         cross-language protocol fixture catalog
tests/lua/                portable Lua test runner and test support
scripts/                  local and CI entry points
.scratch/craftnet-v1/     resolved design and delivery tickets
```

The initial `craftnet-protocol`, `craftnet-core`, and `craftnet-runtime` packages
contain version metadata only. Their protocol, authority, and orchestration
implementations begin in Milestones 1, 2, and 3 respectively.

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
ccpm install craftnet-runtime ^0.1.0
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
