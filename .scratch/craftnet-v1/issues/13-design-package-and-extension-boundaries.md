Type: grilling
Status: resolved
Blocked by: 05, 06, 07, 08, 09, 16

## Question

How should CraftNet responsibilities be divided into deep Lua packages and external-application modules, how should they integrate with the existing `networking` package and `ccpm`, and which seams must support additional ISPs and applications later?

## Answer

CraftNet has two implementations joined by one versioned protocol: Lua 5.2-compatible CC:Tweaked packages for every in-world role and one Go External Application. Package versioning follows semantic versioning independently from wire version `1`. Cross-language examples, canonicalization vectors, signatures, and failure fixtures live under `spec/protocol/v1/` and are the executable compatibility source of truth; neither language imports code from the other.

### Lua package structure

The existing `peripheral-discovery` and `networking` packages remain intact. `networking` is the adapter that discovers and selects wired, wireless, and Ender modems and monitors; it does not acquire CraftNet identities, open protocol sessions, route messages, or own network state.

Three shared packages carry the implementation depth:

| Package | Interface | Hidden implementation |
|---|---|---|
| `craftnet-protocol` | Open an enrolled link, discover/enroll a parent, send a request or notification, and receive validated messages | CJ1 encoding, SHA-256/HMAC, key derivation, schema validation, session handshake, counters, replay rejection, framing, correlation, size limits, modem channels, timeouts |
| `craftnet-core` | Create a role engine from durable state and handle one validated domain input to produce state changes and effects | Address allocation, DNS authority, exact routing, NAT Flow state, Exposed Service policy, topology state, Network Status, errors, revisions, and Traffic Events |
| `craftnet-runtime` | Run one configured role with injected modem, clock, storage, gateway, and screen adapters | CraftOS event loop, parent/child link lifecycle, reconnect backoff, effect execution, atomic snapshots and backup recovery, bounded buffers, and terse status rendering |

The important pure seam is `engine:handle(input, now) -> {state_changes, effects, result}`. Tests drive the same interface used by the runtime. Effects describe sends, replies, persistence, timer creation, screen updates, and Gateway operations; the core never calls peripherals, files, timers, or HTTP directly. The runtime applies an effect and returns its success or failure as the next input, keeping I/O failure behavior explicit.

The protocol package exposes semantic messages rather than its cryptographic helpers. Callers do not calculate MACs, counters, body hashes, or operational channels. Its link interface is deliberately small:

```lua
local link = protocol.open(options)
local result = link:request(kind, body, timeout)
link:notify(kind, body)
link:serve(handler)
link:close()
```

Discovery and enrollment are constructors on the package because they produce an enrolled link rather than a second transport abstraction. Internal codec, crypto, schema, session, modem, and correlation files are not separate `ccpm` packages.

Four role packages are composition roots rather than reusable abstraction layers:

- `craftnet-computer` supplies the join wizard, cached client configuration, Access Token and External Operation helpers, and Computer status screen.
- `craftnet-router` supplies the Customer Router wizard, downstream Computer listener, Address Binding and DNS authority configuration, NAT and forwarding policies, and router screen.
- `craftnet-isp` supplies the ISP wizard, downstream router listener, Provider Address allocation policy, Route Registration forwarding, and ISP screen.
- `craftnet-central` supplies the Central Server wizard, downstream ISP listener, world route map, Network Status authority, topology and traffic aggregation, and the only CraftOS HTTP/WebSocket Gateway adapter.

Each role package contains `setup.lua`, `startup.lua`, and role-specific policy/configuration files and depends on `craftnet-runtime`. Shared behavior moves downward only after two roles need the same invariant. A role entry point may be thin because it is an intentional composition root; it must not grow a second implementation of protocol, persistence, or routing behavior.

The `ccpm` registry publishes the three shared packages and four role packages with immutable version manifests using the repository's existing layout. Applications install exactly one role package; recursive dependencies install the runtime, core, protocol, networking, and peripheral discovery packages. `ccpm` itself remains a package installer and lock-file owner—it gains no role awareness, daemon behavior, secret management, or protocol-version negotiation. First implementation work may add a package-path loader to `ccpm`, but CraftNet can continue using locked absolute paths until that change earns its own ticket.

### Go module structure

The Go application is one deployable binary under `cmd/craftnetd`. Its `internal/` tree uses these modules:

| Module | Interface and responsibility |
|---|---|
| `protocol` | Strict Gateway frame decoding, v1 validation, limits, shared fixture conformance, and stable protocol errors |
| `gateway` | Own one active Gateway Session per World, correlate requests, ingest snapshots/events, and deliver idempotent commands |
| `identity` | Provision Worlds, hash and revoke bearer credentials, issue and verify Ed25519 Access Tokens, and authorize exact ancestry plus operations |
| `operations` | Register named External Operation handlers and dispatch a validated call without exposing HTTP or WebSocket concepts |
| `worldview` | Build topology, traffic, incident, presence, and staleness projections and apply Network Status command results |
| `store` | Execute transactional durable operations spanning identities, projections, commands, Traffic Events, and audit records |
| `web` | Adapt `net/http` requests, cookies, WebSockets, and embedded dashboard assets to the other modules |

`store` is one cohesive transactional interface, not a repository interface per table. Its production adapter is `internal/store/sqlite`; an in-memory adapter exists only in tests. `web` and `gateway` are adapters at the network seams. Domain modules return values and typed errors rather than writing HTTP responses, WebSocket frames, SQL, or logs themselves.

The `operations` registration interface is the intended extension seam for future outside capabilities:

```go
type Handler func(context.Context, Call) (Result, error)
func (r *Registry) Register(name string, policy Policy, handler Handler) error
func (r *Registry) Execute(ctx context.Context, call Call) (Result, error)
```

Adding an operation supplies a handler and policy at the composition root. An adapter to a local model or another real application stays behind that handler; it does not create a new CraftNet route, Gateway Session, message family, or arbitrary URL proxy. There is no generic provider interface until two real handler adapters require different behavior.

### Growth and ownership rules

Additional ISPs, Customer Routers, Customer Networks, and Computers are data instances handled by existing authority maps, never new packages or switch branches. A second ISP exercises the same Central Server child-session collection and exact route map as the first. Additional External Operations use the registry seam. A later wire major version gets a sibling protocol decoder and explicit negotiation; v1 structs and validators remain immutable.

Role ownership remains visible in module names and tests: routers own local addresses, DNS, and NAT; ISPs own Provider Address assignments; the Central Server owns World routes and Network Status; the Go application owns external credentials, operation policy, and historical projections. No shared utility module may mutate those authorities on behalf of a caller.

Verification follows the seams: protocol golden tests run the same JSON fixtures in Lua and Go; core scenario tests run pure event/effect sequences; runtime tests use fake clock, storage, link, and screen adapters; Go module tests use the in-memory store and fake operation handlers; end-to-end tests alone start CC:Tweaked nodes and the real Go binary.
