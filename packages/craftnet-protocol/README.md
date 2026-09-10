# craftnet-protocol

The CraftNet v1 wire, in pure Lua.

```
ccpm install craftnet-protocol
```

**Version 0.1.0 · wire version 1 · no dependencies**

## What it hides

Canonical JSON, SHA-256 and HMAC-SHA-256 written in Lua, key derivation, strict
message schemas, the enrollment and session handshakes, replay counters,
framing, request correlation, size limits, and the stable error catalog.

The point of the package is what a caller **never does**: a caller opens an
enrolled link and exchanges semantic messages. It does not calculate a MAC, a
counter, a body hash, or a canonical form, and `tests/lua/protocol_encapsulation_test.lua`
fails if that surface widens.

```lua
local protocol = dofile("/.ccpm/packages/craftnet-protocol/0.1.0/init.lua")

-- `session` comes from a handshake below; `transport` and `clock` come from
-- craftnet-runtime.
local link = protocol.open({ session = session, transport = transport, clock = clock })
link:send("dns_query", protocol.object({ name = "harvester.farm.acme.craft" }))
```

This is one of **two** implementations of the same wire. The other is
`external/internal/protocol` in Go, and neither is the specification —
[the fixture catalog](../../spec/README.md) is, both replay it, and CI fails if
they disagree. What the wire actually says is
[`docs/protocol/v1.md`](../../docs/protocol/v1.md).

## Surface

### Building values

`object`, `array`, `null`. An empty Lua table is ambiguous on the wire, so an
empty array must be built explicitly with `array({})`; a bare `{}` is an object.

### Links and handshakes

| | |
|---|---|
| `open{session, transport, clock}` | wrap an established session in the link interface |
| `childEnrollment`, `parentEnrollment` | the four-message join, from either side |
| `childSession`, `parentSession` | the three-message reconnect |
| `discovery.seal` / `.open` | the unauthenticated framing that finds a parent |
| `handshake.seal` / `.open` | the outer proof carried before a session key exists |

Discovery and handshake framings are public for one reason: they exist before a
session does, so a role package has to put them on the wire itself. Neither
calculates a MAC, a counter, or a canonical form on the caller's behalf.

### The Gateway

`gateway.encodeHello`, `decodeWelcome`, `encodeFrame`, `decodeFrame` — the
WebSocket envelope, mirroring `external/internal/protocol/gateway.go` field for
field. It signs nothing: the Gateway relies on WSS and the session it opened.

### Tokens

`tokens` issues, displays, normalizes, and matches one-time enrollment tokens:
16 characters of Crockford base32 — no I, L, O, or U, so nothing reads as
something else — carrying 80 bits. The token as typed **is** the enrollment
secret, exactly as a LAN Password is. It is derived from the issuer's root
secret and a counter, so a parent can reissue one an Operator lost and can
recognise which was spent without storing any of them.

`registration.nonce` derives the one-time value a Computer presents when it
registers with the External Application.

### Vocabulary

`validate` answers questions about single values — `identifier`,
`normalizedName`, `operationName`, `customerAddress`, `providerAddress`,
`channel`, `nonce`, `role`, `networkStatus`, and the rest — plus
`credentialUse`, which is the one rule that reads several fields at once. These
are public so `craftnet-core` can check against the wire's own rules instead of
carrying a second copy that could drift.

`errors` is the catalog: `new`, `isKnown`, `retryable`, `meaning`. Every failure
in CraftNet is one of its codes.

`limits` holds every bound the protocol states, so a decoder, a frame writer,
and a test all read the same number.

## Two rules that shape everything

**Derive, never draw.** CraftOS has no cryptographic entropy source worth the
name, so every secret and nonce is derived by HMAC from a durable counter, and
the increment is committed **before** the value is transmitted. A counter kept
only in memory means a restarted role sends a nonce its parent has already seen,
is refused as a replay — correctly — and cannot reconnect.

**Validate in order, commit last.** An inbound frame is checked for types and
size, then relationship, then session, then a strictly increasing counter, then
the body hash, then the MAC — and the counter advances only after the MAC
verifies, so a forged frame cannot move the window.

## Layout

| | |
|---|---|
| `cj1.lua` | CraftNet Canonical JSON 1: the strict decoder, and the only representation handed to HMAC |
| `sha256.lua`, `hmac.lua`, `bitops.lua` | the primitives, with an arithmetic fallback for interpreters without `bit32` |
| `keys.lua` | transcripts and the four derivation labels |
| `schema.lua` | scalars, composites, every message body, and the four transports |
| `frame.lua` | the discovery, handshake, and operational framings |
| `handshake.lua` | enrollment and reconnection, from both sides |
| `link.lua` | an established session as something a caller can send on |
| `gateway.lua` | the WebSocket envelope |
| `tokens.lua` | one-time enrollment tokens |
| `errors.lua`, `limits.lua` | wire constants |

`conformance` exists so the fixture catalog can be replayed in Lua. It is not a
way to reach `sha256`, `cj1`, or `keys` from role code — a role that needs
something gets a purpose-named public surface instead.

## Compatibility

Lua **5.2**, which is what CC:Tweaked provides. CI also runs 5.4, where `bit32`
is absent, to exercise the arithmetic fallback in `bitops.lua`.
