# Working on CraftNet

Conventions this repo enforces that you would otherwise get wrong. Everything
else — layout, commands, what CraftNet is — is in [`README.md`](README.md).

## Language

[`CONTEXT.md`](CONTEXT.md) is the domain vocabulary: 34 terms, each with what it
means and what **not** to call it. Use those words in code, comments, commit
messages, and docs. "Home server" for a Customer Router, or "the network" for
CraftNet, is a defect here.

## Authority

Each role owns a defined slice of state and is the only thing that may decide
it. A Customer Router owns its pool and its Address Bindings; an ISP owns
Provider Addresses; the Central Server owns routes and Network Status. A
snapshot arriving from a parent is merged **only** for the fields that parent
owns — a router receiving a configuration that names its own pool ignores that
part.

When you add a field, decide who owns it before deciding where it lives.

## Purity and the effect seam

`craftnet-core` performs no I/O — no file, no modem, no timer, no clock, no
HTTP. A handler receives `(engine, input, now, out)` and returns **effects as
data** through `out:send`, `out:reply`, `out:gateway`, `out:deliver`,
`out:durable`, `out:event`, `out:timer`. `craftnet-runtime` performs them and
feeds each result back as the next input, so a failed write or a failed send
reaches the authority that cared about it.

Time arrives as the `now` argument. `tests/lua/core_purity_test.lua` fails if a
core module reaches for `fs`, `os`, `peripheral`, or `http`.

CraftOS globals live in `adapter_*.lua` files and nowhere else.

## The wire

Read [`docs/protocol/v1.md`](docs/protocol/v1.md) before touching a message
kind, a field, a limit, or an error code. Then:

- **Both languages change together**, plus the fixtures: `packages/craftnet-protocol/files/schema.lua`,
  `external/internal/protocol/schema.go`, and a case in
  `external/cmd/fixturegen/`. Then `make fixtures`.
- **Fixtures are generated.** Editing `spec/protocol/v1/*.json` by hand fails
  `check-fixtures.sh`. See [`spec/README.md`](spec/README.md).
- A new shape lands with **the rejected cases that pin down what it must
  refuse**, not only an accepted one.
- **Error codes and limits are wire constants.** They change by an ADR, never
  because an implementation found one inconvenient.
- Errors come from `protocol.errors.new(code, …)`. The catalog is the whole
  vocabulary; the dashboard and the HTTP API use the same words.

`protocol.conformance` exists so the fixture catalog can be replayed in Lua. It
is not a way to reach `sha256`, `cj1`, or `keys` from role code — if a role
needs something from the protocol package, give it a purpose-named public
surface (`protocol.registration.nonce` is the pattern).

## Rules with teeth

Each of these has a test that fails without it, and each has cost this project a
real defect:

- **Derive, never draw.** No `math.random` as a security source. Nonces and
  secrets come from HMAC over a **durable** counter, and the increment is
  committed before the value is transmitted. A counter kept only in memory
  breaks reconnection after a restart.
- **Refuse, never queue.** Past a bound, answer `busy`. Refuse at the layer
  where the memory would actually accumulate, not only at the wire.
- **Answer, never hang.** A failure a peer is waiting on travels back as a
  stable code. Silence until timeout is a defect, not a fallback.
- **Secrets live in the secret store.** A state snapshot carries a `*_ref`, never
  a value, so a snapshot can be read, relayed, and shown without anyone
  remembering which field was sensitive.
- **Traffic Events carry metadata only.** The field list is closed and an
  unknown field is refused rather than dropped.
- **An ordinary request is never replayed.** `retryable` says a fresh attempt
  could work; it does not authorize doing it again. Only an idempotent
  administrative command resends, under the same Command ID.
- **Check before you mutate or forward**, and derive identity from the
  authenticated session rather than from what the message claims.

## Packages

A new file under `packages/<name>/files/` must be added to
`packages/<name>/<version>.json`, or `ccpm install` fetches a package that
cannot load. `tests/lua/ccpm_install_test.lua` catches it.

Lua targets **5.2**, which is what CC:Tweaked provides. CI also runs 5.4 to
exercise the arithmetic fallback for `bit32`.

## Comments

Match the surrounding voice: every module opens with a header saying what it is
for and why it works this way, and inline comments explain the reasoning a
reader could not recover from the code. Write what a teammate would write —
prose about the design, in the present tense, with no authorship or tooling
markers.

Worth reading one file to calibrate: `packages/craftnet-core/files/role_router.lua`.

## Finishing

The gate is `make fmt-check` and `make test` — run both.

A milestone lands with its regression tests, a `docs/implementation/milestone-N.md`
recording what it delivered **and what it did not prove**, and an ADR for any
decision that shapes later work. Record a blocked scenario as blocked. A gate
that says what actually happened is worth more than one that waits until it can
say everything passed.

## Pointers

| Reach for | When |
|---|---|
| [`CONTEXT.md`](CONTEXT.md) | naming anything |
| [`docs/protocol/v1.md`](docs/protocol/v1.md) | changing a message, limit, or error code |
| [`spec/README.md`](spec/README.md) | adding or regenerating a fixture |
| [`docs/contributing.md`](docs/contributing.md) | writing a test, or adding an External Operation |
| [`docs/architecture.md`](docs/architecture.md) | you need how the pieces fit today |
| [`docs/adr/`](docs/adr/) | you are about to contradict a settled decision |
| [`docs/operations/`](docs/operations/) | changing anything an Operator types or sees |
