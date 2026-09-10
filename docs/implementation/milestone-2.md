# Milestone 2 — Pure network authority engine

Status: complete on 2026-09-09.

Milestone 2 implements `craftnet-core`: the state transitions that decide what
CraftNet does. Addressing, DNS, routing, NAT, exposure policy, Network Status,
revisions, failures, and Traffic Events all live here now, and none of it
touches a peripheral, a file, a timer, or a socket. Milestone 3 gives this
engine a runtime; Minecraft is not involved in any of it yet.

## The seam

```lua
local engine = core.newEngine({ role = "router", state = durableState })
local outcome = engine:handle(input, now)
-- outcome = { state_changes, effects, result, revision }
```

An effect is a description, not an action. The runtime performs it and reports
back by feeding the answer in as the next input, which is what keeps I/O failure
behaviour explicit rather than hidden inside the engine. The tests and the
simulator drive exactly the interface the runtime will.

## Delivered

### `craftnet-core`

| Module | Owns |
|---|---|
| `engine` | Dispatch, authenticated-peer lookup, Traffic Event recording, shared link and tick transitions |
| `outcome` | The `{state_changes, effects, result}` builder, revision bumping, and the single persist per transition |
| `ipv4` | Address and range arithmetic, lowest-free allocation, disjoint block carving |
| `names` | CraftNet Name normalization, the delegated hierarchy, and `api.craft` |
| `events` | Traffic Event construction with redaction by whitelist, and the rolling buffers |
| `flows` | Paired NAT Flows and request correlation, with idle expiry |
| `role_router` | The RFC 1918 pool, Address Bindings, local DNS, Exposed Services, NAT, forwarding |
| `role_isp` | The Customer Router registry, Provider Address assignment, Route Registration, relaying |
| `role_central` | The ISP registry, the RFC 6598 allocator, the exact route directory, Network Status, topology |
| `role_computer` | Cached configuration, name classification, application request and response |

### The deterministic simulator

`tests/lua/support/simulator.lua` runs many engines against a fake clock. It
supplies only what the core deliberately does not do: relationships between
nodes, a queue that turns one engine's `send` effect into another's `message`
input, controllable message loss, and inspection. Nothing in it simulates
CraftNet behaviour — every scenario runs through the real state transitions.

`tests/lua/support/reference.lua` builds the canonical reference topology from
the verification design, and builds it the honest way: no address, route, or
binding is written into an engine's state by hand. Every one of them was decided
by `craftnet-core`, and the result matches the fixture exactly:

```text
World: Overworld [world-overworld]
└── Central Server [central-main]
    └── Acme ISP [isp-acme]   allocation 100.64.0.0-100.64.0.255, ISP 100.64.0.1
        ├── Home [network-home]   router 100.64.0.10, pool 192.168.1.20-39
        │   ├── alex-pc        192.168.1.20
        │   └── wall-display   192.168.1.21
        └── Farm [network-farm]   router 100.64.0.11, pool 192.168.1.20-39
            ├── harvester      192.168.1.20
            └── silo-monitor   192.168.1.21
```

## Gate evidence

The Lua suite runs 113 tests. Scenarios 3 through 7 pass with no real
peripherals:

| Gate requirement | Evidence |
|---|---|
| Overlapping addresses remain unambiguous | `core_scenarios_test.lua` scenario 3; both networks bind `.20` and `.21`, and the route directory keys on identity |
| Local delivery creates no NAT | scenario 5; the router's flow table stays empty and neither the ISP nor the Central Server sees the traffic |
| The Central path is used even within one ISP | scenario 6 and `core_authority_test.lua`; the observed path visits Acme twice, around Central |
| Replies follow paired flows | scenario 6; the far half names the near half, and the reply reaches Home's `.20` rather than Farm's |
| Missing, expired, and disabled paths fail distinctly | scenario 7; `route_not_found`, `nat_flow_missing`, `network_disabled`, `inbound_denied`, `pool_exhausted` |
| Authority ownership cannot be bypassed | `core_authority_test.lua`, 11 attacks from below |
| Seeded runs never allocate an address twice in one scope | `core_property_test.lua`; 400 seeded joins and releases, checked against the router's own view at every step |
| Seeded runs never route a reply to the wrong Computer | `core_property_test.lua`; 150 seeded requests across a World where every network reuses the identical pool |

Interpreter and seed coverage:

```text
LUA_BIN=lua5.2 CRAFTNET_TEST_SEED=12648430 bash scripts/test-lua.sh
LUA_BIN=lua5.2 CRAFTNET_TEST_SEED=42       bash scripts/test-lua.sh
LUA_BIN=lua5.4 CRAFTNET_TEST_SEED=42       bash scripts/test-lua.sh
LUA_BIN=luajit CRAFTNET_TEST_SEED=7        bash scripts/test-lua.sh
make fmt-check && make test
```

The property tests pass at every seed tried, so they are testing an invariant
rather than one lucky ordering.

## Decisions made inside this milestone

- **Provider Addresses may be named by the Operator.** Ticket 8 says an ISP
  assigns "the lowest available" Provider Address, while the reference topology
  in ticket 14 fixes Acme at `100.64.0.1` and its routers at `.10` and `.11` —
  which is not what lowest-free produces. Both are satisfied: lowest-free is the
  default and is tested on its own, and an Operator may name an address instead,
  provided it falls inside the ISP's own delegated allocation and nobody holds
  it. An ISP still cannot widen its range by asking.
- **`api.craft` is classified, not looked up.** `dns_result` is fixed by ticket
  16 to carry a Customer Network, a Computer, and an address, none of which the
  External Application has. A Computer therefore recognizes `api.craft` locally
  and reaches it through an External Operation and its verified ancestry. A
  router that is asked to resolve it answers `name_not_found` with a message
  saying so, rather than inventing a wire field.
- **`craft` is reserved.** A bare `craft` names nothing, because it is the
  world-local suffix. A Computer actually called `craft` stays reachable once
  the name is qualified.
- **Intermediate hops correlate; routers pair flows.** The paired flow
  identifiers required by ticket 7 travel end to end and are what the source
  router uses to find its Computer — which is what makes an expired flow fail
  with `nat_flow_missing`. ISPs and the Central Server additionally keep
  ephemeral correlation records keyed by the outgoing leg, so a reply retraces
  the exact path its request took instead of being re-routed.
- **A `deliver` effect is the application seam.** The core has no idea what any
  service does. When a request reaches its Computer, the core records what must
  be answered and emits `deliver`; the application replies through
  `application_response`.
- **Traffic Event redaction is a whitelist.** `events.new` refuses an unknown
  field rather than dropping it, so a caller that tries to attach a payload
  finds out immediately instead of shipping an event that quietly lost
  information. A field that is never constructed cannot leak.
- **`craftnet-protocol` gained a `validate` surface.** The protocol package owns
  what a CraftNet identifier, name, and address are. Exposing the predicates
  publicly lets `craftnet-core` check values against the wire's own rules
  instead of carrying a second copy that could drift.
- **`craftnet-core` takes its protocol by injection.** `core.withProtocol()` is
  called once at a composition root. Core performs no file access of its own —
  not even to locate its sibling package — because it must remain pure.

## Deliberately deferred

- Heartbeats, Connectivity State thresholds, reconnect backoff, snapshots, and
  screen rendering are Milestone 3, where a runtime exists to own them. The
  engine emits `timer` and `screen` effects but nothing yet consumes them.
- The Central Server's Gateway effects are declared and unused until Milestone 6.
- `topology_snapshot` currently reports ISPs, routers, and Network Status.
  Computers appear in it when Milestone 5 gives the Central Server a child
  summary to aggregate from.
- Scenarios 1, 2, and 8 through 12 need enrollment wizards, the Go application,
  or a real restart, and belong to Milestones 4, 5, 6, and 8.

Milestone 3 is the next implementation gate: `craftnet-runtime` — CraftOS event
orchestration, the modem adapter, atomic versioned snapshots with one backup,
bounded backoff, and terse status rendering.
