# The protocol fixture catalog

This directory is the **executable specification** of the CraftNet v1 wire. Two
independent implementations — `craftnet-protocol` in Lua and
`external/internal/protocol` in Go — replay it, and CI fails if they disagree
about a single case.

It is the authority. [`docs/protocol/v1.md`](../docs/protocol/v1.md) explains
what it encodes and why; where the two conflict, the fixture is right.

The point of a shared catalog is narrow and worth stating: it is not that both
implementations are correct, which nothing here can prove. It is that they are
**wrong in the same way or not at all** — that a frame one accepts is not one
the other silently reinterprets.

## Layout

```text
spec/protocol/v1/
  manifest.json          the index; every fixture is listed here or it is not run
  cj1/                   canonical JSON: what encodes, and what must not decode
  derivation/            key derivation vectors for all four labels
  errors/                the stable error catalog
  frames/                operational frames, plus counter/replay sequences
  gateway/               Gateway hello, welcome, and frames
  handshake/             enrollment and session transcripts, end to end
  hash/                  SHA-256 and HMAC-SHA-256 vectors
  limits/                the edge of every bound, from both sides
  messages/              message bodies against their kinds
  tokens/                Ed25519 Access Token vectors
```

## The manifest

`manifest.json` carries `schema`, `wire_version`, and a list of fixtures. Each
entry says:

| Field | Meaning |
|---|---|
| `path` | the file, relative to `spec/protocol/v1/` |
| `kind` | which replay routine handles it — `cj1`, `message`, `frame`, `frame_sequence`, `gateway_frame`, `enrollment`, `session`, `key_derivation`, `sha256`, `hmac_sha256`, `error_catalog`, `limits`, `access_token` |
| `expect` | `valid` — every case must be accepted; `invalid` — every case must be refused, **with the stated error code**, not merely refused |
| `consumers` | which implementations must replay it: `lua`, `go`, or both |

An `invalid` fixture asserts the *code*, not just the failure. "It threw
something" is not a passing result — a frame that should be `message_too_large`
and comes back `invalid_message` is a bug, because an Operator is told to act on
the code.

**A fixture not listed in the manifest does not run.** Adding a file is not
enough.

## Who replays what

| Implementation | Entry point |
|---|---|
| Lua | `tests/lua/support/catalog.lua`, driven by `tests/lua/protocol_conformance_test.lua` |
| Go | `external/internal/catalog`, with `external/internal/fixtures` validating the manifest itself |

The Lua reader decodes each fixture with the protocol package's **own strict
decoder**, so reading the catalog exercises the decoder before a single case
runs. The catalog is authored to stay inside the wire limits for exactly that
reason.

### Two fixtures are Go-only

`gateway/frames.json` and `tokens/access-token.json` list `go` alone as their
consumer.

For the Access Token that is correct and permanent: CraftOS treats a token as
opaque, never verifies an Ed25519 signature, and never reads a claim out of one.
There is nothing for Lua to replay.

For `gateway/frames.json` it is a **gap, not a decision**. Since Milestone 9 the
Lua side has a Gateway codec of its own (`packages/craftnet-protocol/files/gateway.lua`)
which is not held to these vectors, so the two ends of that socket are checked
against each other only by inspection. Adding `lua` to that fixture's consumers
and a replay routine to `catalog.lua` is worth doing.

## Regenerating

The catalog is **generated, not hand-written**. Its source is
`external/cmd/fixturegen`, which builds each case through the Go implementation
and refuses to emit one that its own validator disagrees with — so a fixture
cannot be committed asserting something the code does not do.

```bash
make fixtures      # regenerate from external/cmd/fixturegen
make test          # replay in both languages
```

`scripts/check-fixtures.sh` regenerates into a scratch directory and diffs. A
catalog that does not reproduce byte for byte fails CI, which is what stops a
fixture from being edited by hand to make a test pass.

## Adding a case

1. Add it to the right table in `external/cmd/fixturegen/` — `messages.go`,
   `frames.go`, `gateway.go`, `handshakes.go`, `canonical.go`, `derivation.go`,
   or `limits.go`.
2. For a new shape, add **both** an accepted case and the rejected cases that
   pin down what it must refuse. An accepted case alone documents the happy path
   and defends nothing.
3. `make fixtures`, then `make test`.
4. If it is a new message kind or field, both schemas change too, and
   [`docs/protocol/v1.md`](../docs/protocol/v1.md) with them.

Changing an existing fixture means changing the wire, which is an ADR-level
decision — see [Changing any of this](../docs/protocol/v1.md#changing-any-of-this).
Convenience is not a reason.
