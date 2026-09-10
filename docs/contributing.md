# Contributing

How to run the suites, pick a test harness, and extend the two things people
extend most.

Conventions this repo enforces are in [`AGENTS.md`](../AGENTS.md) — worth reading
first whether or not you are an agent.

## The gate

```bash
make fmt-check
make test
```

`make test` runs, in order: the Lua suite, the fixture catalog in both
languages, the `ccpm` package catalog, a regeneration diff of the fixtures, and
the Go suite under `-race`. Individual scripts are in `scripts/`.

Two environment variables matter:

| Variable | Does |
|---|---|
| `LUA_BIN` | which interpreter to use — `lua5.2`, `lua5.4`, `luajit`, or whatever is on `PATH` |
| `CRAFTNET_TEST_SEED` | seeds every property-style and load test; the default is `12648430` |

```bash
CRAFTNET_TEST_SEED=42 make test        # a different seed
LUA_BIN=lua5.4 bash scripts/test-lua.sh
```

**A failing seeded run is reproducible.** The seed is printed at the top of
every Lua run; quote it in the bug.

CI runs the whole gate on Lua **5.2** — the version CC:Tweaked provides, and the
one the code must work on — then runs the Lua suite again on **5.4** at a
different seed. 5.4 removed `bit32`, so that second run is what exercises the
arithmetic fallback in `packages/craftnet-protocol/files/bitops.lua`.

## The Lua test runner

`tests/lua/test_runner.lua` is about forty lines and supplies three globals:
`test(name, body)`, `assertEqual(actual, expected, message)`, and
`assertTrue(value, message)`. Output is TAP-ish; the process exits non-zero on
the first failure to load a file, and reports a count at the end.

A suite is a file matching `tests/lua/*_test.lua`. It is found automatically —
there is no list to update. It loads the packages it needs by `dofile` and
support modules by `require`:

```lua
-- What this suite is for, and why it is arranged this way.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local runtimePackage = dofile("packages/craftnet-runtime/files/init.lua")
  .withPackages({ protocol = protocol, core = core })
local fakes = require("tests.lua.support.fakes")

test("what must be true, stated as a claim", function()
  -- ...
end)
```

Name a test as the **claim it defends**, not as the function it calls: "a
restarted role reconnects to a parent that did not restart" beats "test
reconnect".

## Which harness

Four of them, in ascending order of how much World they stand up. Reach for the
smallest that can express the claim — a scenario that needs a whole World is
slower to run and much slower to read.

| Harness | Stands up | Reach for it when |
|---|---|---|
| `support/fakes.lua` | one runtime over fake clock, storage, links, screen, gateway | the claim is about one role: persistence, reconciliation, connectivity, effects |
| `support/simulator.lua` | many `craftnet-core` engines, a clock that moves when you say so, and a queue turning one engine's `send` into another's `message` | the claim is about state transitions across roles, with no I/O involved |
| `support/lanworld.lua` | a cooperative fake LAN over coroutines, carrying the **real** links adapter, protocol, and engines | the claim involves a conversation — enrollment, a join, a reconnect |
| `support/world.lua` | the whole reference topology, provisioned the way an Operator would: a bundle, tokens carried screen to screen, Computers joining with a LAN Password | the claim is end to end |

Supporting cast:

- `support/reference.lua` — the canonical topology's fixture values. The same
  Home/Farm names, networks, and addresses the in-world acceptance run uses, so
  a passing scenario describes the deployment someone actually builds.
- `support/craftos.lua` — stand-ins for CC:Tweaked globals.
- `support/catalog.lua` — reads the shared fixture catalog. See
  [`spec/README.md`](../spec/README.md).
- `support/seed.lua`, `support/temp_state.lua` — the seed, and state directories
  that live outside the repository.

**Nothing here mocks CraftNet behaviour.** Every harness drives real engines and
real state transitions; only the modem, the disk, and the clock are imaginary.
A scenario that passes in the simulator passed through the same transitions the
runtime drives in Minecraft. Keep it that way — a mock of a role would let a
test pass while the thing it describes is broken.

`world.lua` runs each node in a coroutine, so drive it through `world:pump(fn,
except)`: `fn` is the driver, `except` names the node the driver is speaking
for, and every other node serves itself meanwhile.

## Check that a regression test regresses

A test that passes whether or not the code is right defends nothing. Before
calling one done, **break the thing it covers and watch it fail** — comment out
the guard, invert the condition, delete the branch — then put it back:

```bash
# edit the code, then
make test-lua
git checkout -- packages/craftnet-core/files/role_router.lua
```

Every milestone in this repository claims its regression tests fail without
their fix. That claim is only worth making if someone checked.

## Adding an External Operation

An operation is a **handler plus a policy** at the composition root. There is no
new route, no new message family, and no proxy to a URL. An empty allowlist is
the right default, and this is the whole of what widening it takes.

In `external/internal/app/app.go`, inside `registerOperations`:

```go
err = a.Operations.Register("market.quote", operations.Policy{
	Credential:  operations.CredentialAccessToken,
	Description: "Quote a price for one commodity",
}, func(ctx context.Context, call operations.Call) (operations.Result, error) {
	symbol, _ := call.Payload["symbol"].(string)
	if symbol == "" {
		return operations.Result{}, &protocol.Error{
			Code:    protocol.CodeInvalidMessage,
			Message: "a symbol is required",
		}
	}
	return operations.Result{Payload: protocol.Object{"price": int64(19)}}, nil
})
if err != nil {
	return err
}
```

Then add the name to `DefaultOperations` in the same file.

Three things to get right:

- **Pick the credential class deliberately.** `CredentialAccessToken` for
  ordinary work; `CredentialDevice` only for something that issues or rotates a
  credential; `CredentialAncestry` only where the verified CraftNet path is
  genuinely the whole attestation, as it is for `device.register`. The wire
  enforces the matching combination at both ends — see
  [the protocol reference](protocol/v1.md#naming-the-external-application).
- **Fail with a catalog code.** Return a `*protocol.Error` carrying one of the
  stable codes. An Operator matches on the code, and
  [Recovery](operations/recovery.md) lists what each one means.
- **There are no decimals on the wire.** Use a scaled integer or a string.

Call it from in world with `craftnet call api.craft market.quote`.

## Adding a role program

A program is a file under `packages/<role>/files/` **and an entry in
`packages/<role>/<version>.json`**. Without the manifest entry, `ccpm install`
fetches a package that cannot load; `tests/lua/ccpm_install_test.lua` catches
it.

`tests/lua/role_programs_test.lua` holds every documented program to one bar: it
compiles, it reaches for no global CC:Tweaked does not provide, it says
something actionable when it cannot start, and it never prints or unmasks a
secret. A new program joins that list.

Document it in [the setup guide's command table](operations/setup.md) too — the
gate says a second Operator must be able to work from the documentation without
reading source.

## Changing the wire

See [`AGENTS.md`](../AGENTS.md#the-wire) and
[the protocol reference](protocol/v1.md#changing-any-of-this). Short version:
decide it in an ADR, change both schemas, add fixtures for what it accepts
**and** what it must now refuse, `make fixtures`, update the reference.

## Go

Each file opens with a header comment **below** the package clause explaining
what it is for — follow the surrounding file rather than moving it above. A
package-level `doc.go` is for the package as a whole, where one earns its place.

`storetest` is one suite run against both the in-memory and the SQLite adapter,
so a store change is tested twice by writing it once. SQLite migrations are
forward-only and tested from the previous checked-in version.
