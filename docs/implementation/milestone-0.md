# Milestone 0 — Reproducible project skeleton

Status: complete on 2026-09-08.

## Delivered

- A dependency-free Go 1.27 module and buildable `craftnetd` composition root
- Portable Lua test runner, deterministic Park–Miller test generator, and isolated temporary-state helper
- Equivalent deterministic seed and temporary-state helpers for Go tests
- Versioned, language-neutral protocol fixture catalog and strict validator
- Strict local `ccpm` registry/manifest/source consistency validator
- `craftnet-protocol`, `craftnet-core`, and `craftnet-runtime` package skeletons at `0.1.0`
- Local test and format entry points through shell scripts and `make`
- GitHub Actions CI using Lua 5.2, Go 1.27, the race detector, and read-only repository permissions
- Recorded Minecraft, Fabric, CC:Tweaked, Go, and wire-protocol versions
- Ignore rules for credentials, databases, runtime state, and build output

## Gate evidence

The following checks pass:

```text
make fmt-check
make test
LUA_BIN=luajit CRAFTNET_TEST_SEED=42 bash scripts/test-lua.sh
go vet ./...
go test -race -run TestValidateRejectsMalformedManifest -v ./internal/fixtures
```

The Lua suite also passes under Lua 5.2 in a read-only Ubuntu 24.04 container.
The malformed-manifest test proves the negative validator path. The catalog
check confirms every registry entry, manifest identity, dependency name, source
path, and immutable GitHub URL. `ccpm.lua`, `networking`, and
`peripheral-discovery` sources are unchanged, and the gate generates no database
or secret-like files in the repository.

Milestone 1 is the next implementation gate: protocol fixtures, CJ1, SHA-256,
HMAC, enrollment/session authentication, replay protection, and Gateway framing.
