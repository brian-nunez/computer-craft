Type: grilling
Status: resolved
Blocked by: 10, 11, 12, 13, 14

## Question

In what sequence should the agreed components be implemented, integrated, demonstrated, and released, and what evidence is required to pass each milestone before work expands?

## Answer

CraftNet is delivered in eight gated milestones. Work may fix defects in an earlier milestone at any time, but functionality from a later milestone does not enter the main implementation branch until the current gate passes. This keeps protocol, authority, and recovery mistakes from being buried beneath the dashboard or full Minecraft integration.

All Lua is compatible with CC:Tweaked's Lua 5.2 environment. The external code is a Go module rooted at `external/`, producing `external/cmd/craftnetd`. Shared protocol artifacts live at `spec/protocol/v1/`; Lua packages continue the existing `packages/<name>/` plus `ccpm` manifest convention. New packages begin at semantic version `0.1.0`; wire version remains independently fixed at `1` for the entire v1 release.

### Milestone 0 — Reproducible project skeleton

Create the directory structure, Lua test runner, Go module, CI entry points, protocol-fixture validator, deterministic seed handling, temporary-state helpers, and commands documented in the root README. Add package manifests for `craftnet-protocol`, `craftnet-core`, and `craftnet-runtime`, but no role behavior yet. Pin direct Go dependencies and record the Minecraft, Fabric, CC:Tweaked, and Go versions used by acceptance reports.

**Gate:** a clean checkout runs the empty Lua and Go suites with one command each; `go test -race ./...` passes; fixture validation detects a deliberately malformed fixture; no generated state or secret enters Git. The existing `ccpm`, `networking`, and `peripheral-discovery` tests and behavior remain unchanged.

### Milestone 1 — Protocol and authentication kernel

Check in v1 valid/invalid message fixtures, CJ1 golden encodings, SHA-256/HMAC vectors, enrollment/session transcripts, error examples, limit edges, and Ed25519 JWT fixtures. Implement `craftnet-protocol` in Lua and `external/internal/protocol` in Go. Lua owns modem framing, strict schemas, authentication, replay counters, session establishment, request correlation, size limits, and timeouts; Go initially needs Gateway framing and fixture conformance. A minimal Go provisioning command uses `crypto/rand` to create a development World Key and Gateway Credential bundle so no CraftOS role invents root secrets or relies on checked-in fixture credentials.

**Gate:** Lua and Go classify every fixture identically and produce byte-identical CJ1 where both participate. Published SHA/HMAC vectors pass; a changed field, body, counter, relationship, or session fails authentication; replay and out-of-order counters fail closed; exactly-limit frames pass and oversized/deep/sparse/unknown-control frames fail with their specified errors. No caller outside the package handles MACs or canonicalization.

### Milestone 2 — Pure network authority engine

Implement `craftnet-core` as pure role state transitions: delegated IDs and names, RFC 1918 validation and lowest-free Address Bindings, hierarchical DNS, RFC 6598 Provider Allocations, exact Route Registrations, Exposed Services, paired NAT Flows, Network Status, revisions, stable failures, and redacted Traffic Events. Build the deterministic multi-role simulator around `engine:handle` using fake time and effect collection.

**Gate:** simulator scenarios 3–7 pass without real peripherals: overlapping addresses remain unambiguous; local delivery creates no NAT; the Central path is used even within one ISP; replies follow paired flows; missing/expired/disabled paths fail distinctly; authority ownership cannot be bypassed. Property-style seeded runs never allocate an address twice within one scope or route a reply to the wrong Computer.

### Milestone 3 — Runtime, persistence, and recovery

Implement `craftnet-runtime`: CraftOS event orchestration, the modem adapter through the existing `networking` package, link lifecycle, durable generation counters, atomic versioned snapshots with one backup, revisions, heartbeat state, bounded backoff, effect execution, Traffic Event buffers, and terse terminal rendering. Add fake storage, link, clock, screen, and Gateway adapters.

**Gate:** restart and disconnect simulations preserve every durable field and discard every ephemeral field; a corrupt primary loads its valid backup; reconciliation obeys authority ownership; Connectivity State changes at the specified thresholds; pending ordinary requests are not replayed; buffers remain at 100/500/2,000. Tests demonstrate that core modules perform no filesystem, modem, timer, HTTP, or screen I/O directly.

### Milestone 4 — Local Customer Network vertical slice

Publish initial `craftnet-computer` and `craftnet-router` packages. Implement `craftnet setup router`, `craftnet join`, LAN Password challenge-response and rate limiting, permanent client credentials/configuration, local DNS, local Exposed Services, local request/reply, startup programs, and minimal Computer/router screens. First prove this with Home alone, then add Farm using the identical LAN range.

**Gate:** reference scenarios 2, 4, and 5 pass in the simulator and on a small in-world wired or wireless LAN. Four Computers join through passwords, wrong passwords fail, both networks allocate `.20` and `.21`, local names resolve, local requests never leave their router, and restart does not change identity/address. Installing a role through `ccpm` brings all dependencies into the lock file from a clean Computer.

### Milestone 5 — Central and ISP internetwork

Publish `craftnet-isp` and `craftnet-central`. Implement their setup wizards, one-time enrollment, Ender-modem Logical Interfaces, operational-channel allocation, Provider Allocation and addresses, Route Registration, Central exact routing, cross-network forwarding, paired NAT replies, topology aggregation, and Central Network Status enforcement. Use a development provisioning bundle generated by the Milestone 1 Go command; never hard-code a World Key or Gateway Credential.

**Gate:** reference scenarios 1, 3, 6, and 7 pass in deterministic simulation and the in-world topology. The observed Home→Farm path includes both visits to Acme around Central, identical `.20` addresses never collide, unsolicited inbound traffic fails, and removing/restoring an ISP or route changes reachability without deleting durable assignments. Multi-ISP simulation proves every Provider Allocation is disjoint and no ISP can claim another ISP's route.

### Milestone 6 — Go External Application and Gateway

Build the real `craftnetd` composition root using `net/http`, `github.com/coder/websocket`, `database/sql`, and `modernc.org/sqlite`. Implement configuration, migrations, durable World provisioning, hashed Gateway and Device Credentials, the one-Gateway-per-World registry, topology/event ingestion, named operation registry, `device.register`, `token.issue`, Ed25519 Access Tokens, verified ancestry, request correlation, retention pruning, and transactional command storage. Replace the development bundle workflow in the Central wizard with the persisted Gateway Credential and World Key flow.

**Gate:** all Go unit and race tests pass against in-memory and temporary SQLite adapters as appropriate. Gateway integration tests prove authentication, one live session per World, reconnect snapshots, sequence-gap staleness, command idempotency, two-minute token expiry, exact ancestry matching, allowlist rejection, and database rollback. Reference scenario 8 passes end to end; disabling the Go process leaves internal scenarios 5 and 6 working while external requests return `gateway_unavailable`.

### Milestone 7 — Operator dashboard and administration

Implement the embedded same-origin dashboard with authenticated cookie sessions. The primary Topology canvas follows validated variant B; linked Traffic and Incidents views use variants A and C. Add filters, node inspection, Connectivity State and staleness, credential status without values, NAT/event metadata, and confirmed Enable/Disable Customer Network commands with audit history.

**Gate:** reference scenarios 9 and 10 pass. The dashboard shows the entire fixture and all required outcomes, selection carries across views, payloads/tokens/MACs/passwords never appear, a disconnected Gateway visibly makes data stale, duplicate commands are harmless, disabling Farm rejects all new Farm operations but retains configuration, and re-enabling restores traffic without enrollment. HTTP authorization and WebSocket origin tests fail closed.

### Milestone 8 — Hardening, scale, and v1 release

Run the complete restart matrix, role outages, Gateway outage, pool exhaustion, route removal, NAT expiry, credential revocation, malformed input corpus, 1,000-request reference load, and the 1,685-entity/10,000-operation scale simulation. Complete operator setup/recovery documentation and execute all twelve acceptance scenarios in the target Minecraft stack from clean Computers and a clean Go data directory.

**Gate:** every threshold in ticket 14 passes with no required skip. The checked-in acceptance report names exact versions and commit, secrets are redacted, database migrations succeed from an empty database and the previous release candidate, role snapshots survive the restart matrix, and no test observes wrong-recipient delivery, unauthorized operation, payload-bearing telemetry, unbounded queues, or leaked active flow state. A second Operator can follow the documentation without editing source.

After the gate, publish the seven Lua packages and their `ccpm` manifests at `0.1.0`, build checksummed `craftnetd` binaries/container artifacts, tag the repository `v0.1.0`, and archive the acceptance report. The release notes explicitly state the tested scale and v1 exclusions rather than presenting architectural extensibility as unlimited measured capacity.

### Working rules across milestones

- Each milestone begins with its gate expressed as failing automated tests or an acceptance checklist and ends only when that evidence passes.
- Protocol fixtures and stable errors change only by an explicit wire-version decision; implementation convenience does not silently revise them.
- All security and authority checks occur before state mutation or forwarding. Failure telemetry is redacted at creation, not cleaned later by the dashboard.
- SQLite migrations and CraftOS snapshot migrations are forward-only, versioned, and tested from the immediately preceding checked-in version.
- New seams require two real adapters or a demonstrated test need. Role entry points may be thin composition roots; shared domain behavior belongs behind the three agreed Lua interfaces.
- The reference topology remains the first end-to-end test. Scale fixtures supplement it and never replace the player-visible Home/Farm demonstration.
