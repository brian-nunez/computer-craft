# craftnet-core

Pure role state transitions. No file, no modem, no timer, no clock.

```
ccpm install craftnet-core
```

**Version 0.1.0 · wire version 1 · depends on `craftnet-protocol` ^0.1.0**

## What it hides

Everything CraftNet decides: delegated identities and names, RFC 1918 validation
and lowest-free Address Bindings, hierarchical DNS, RFC 6598 Provider
Allocations, exact Route Registrations, Exposed Services, paired NAT Flows,
Network Status, revisions, stable failures, and redacted Traffic Events.

What it does **not** do is anything at all. A handler answers "what should
happen"; it never makes it happen.

```lua
local core = dofile("/.ccpm/packages/craftnet-core/0.1.0/init.lua")
  .withProtocol(protocol)

local engine = core.newEngine({ role = "router" })
local outcome = engine:handle({ kind = "bind_computer", computer_id = "cmp-1" }, now)

outcome.result   --> { ok = true, address = "192.168.1.20" }
outcome.effects  --> { { kind = "persist", … }, { kind = "event", … } }
```

Time arrives as the `now` argument. `tests/lua/core_purity_test.lua` fails if any
module here names `fs`, `os`, `peripheral`, or `http`.

## The effect seam

```text
input ──▶ handler ──▶ effects (data)
                          │
              craftnet-runtime performs them
                          │
                result ──▶ back in as the next input
```

A handler receives `(engine, input, now, out)` and describes what it wants
through the `out` builder:

| | |
|---|---|
| `out:send` / `out:reply` / `out:replyError` | a message on a relationship |
| `out:gateway` | a message on the Central Server's Gateway Session |
| `out:deliver` | hand a request to the application on this Computer |
| `out:durable` / `out:ephemeral` | a state change that must be persisted, or one that must not |
| `out:event` | a Traffic Event |
| `out:timer` | a wake-up; the core never sleeps or polls |
| `out:ok` / `out:fail` | the result, with a catalog code on failure |

The feedback loop is the point. A failed write or a failed send comes back as an
input, so the authority that cared about it finds out — instead of the problem
disappearing inside an adapter.

It is also what makes a whole World testable: the deterministic simulator drives
these transitions with a fake clock and a queue, and a scenario that passes there
passed through the same code that runs in Minecraft.

## Surface

| | |
|---|---|
| `withProtocol(protocol)` | bind the package to its protocol and get the API |
| `newEngine{role, state?}` | one role's engine over its authoritative state |
| `names` | `parse`, `normalize`, `canonical`, `isLocal`, and the `.craft` suffix |
| `ipv4` | ranges, containment, and lowest-free allocation |
| `events` | Traffic Event construction and the rolling buffers |
| `errors`, `object`, `array`, `null` | passed through from the protocol |

An engine exposes `state`, `links`, `flows`, `transit`, `buffer`, and — for the
Central Server alone — `gateway`, the Gateway Session's own in-flight table.

## The four roles

Each is one file, and each owns a defined slice of state that nothing else may
decide.

| | Owns |
|---|---|
| `role_computer` | its application. Nothing about the network — its router is authoritative for membership and address |
| `role_router` | the RFC 1918 pool, Address Bindings, local DNS, Exposed Services, NAT Flows. The only role that sees a Computer, and where "who is asking" stops being a claim |
| `role_isp` | its Provider Allocation and which Customer Routers it serves |
| `role_central` | the World identity, the ISP registry, the RFC 6598 allocator, the exact route directory, Network Status, and the Gateway |

## Rules with teeth

Each has a test that fails without it, and each cost this project a real defect.

**Refuse, never queue.** Bounded at 64 in flight per relationship and 256 through
the Gateway; past that, `busy`. The refusal happens at the layer where the memory
would actually accumulate, not only at the wire — a bound held one level up lets
the memory grow underneath it.

**Answer, never hang.** A failure a peer is waiting on travels back as a stable
code. Silence until timeout is a defect.

**Never replay.** An interrupted request is gone. `retryable` says a fresh
attempt could work; it does not authorize doing it again.

**A Traffic Event carries metadata only.** The field list is closed and an
unknown field is refused rather than dropped, so a caller that tries to attach a
payload finds out immediately instead of shipping an event that quietly lost
information. Redaction happens at construction, not at display.

**Derive identity, never believe it.** A Customer Router rebuilds `source` from
the authenticated session; an ISP checks a router speaks only for its own
Customer Network; the Central Server stamps ancestry from the route directory.

## Layout

| | |
|---|---|
| `engine.lua` | one pure transition per input, and the transitions every role shares |
| `outcome.lua` | the effect builder |
| `flows.lua` | NAT Flows and request correlation, with their idle expiry and bounds |
| `events.lua` | Traffic Events and the rolling buffers |
| `names.lua` | the delegated `.craft` hierarchy |
| `ipv4.lua` | address arithmetic and lowest-free allocation |
| `role_*.lua` | one file per role |

## Read next

[Architecture](../../docs/architecture.md) for how the roles fit together, and
[the wire](../../docs/protocol/v1.md) for what they say to each other.
