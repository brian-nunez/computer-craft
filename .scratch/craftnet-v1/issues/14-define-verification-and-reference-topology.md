Type: grilling
Status: resolved
Blocked by: 01, 06, 07, 08, 09, 11, 16

## Question

Which automated tests, simulators, in-world checks, and acceptance scenarios prove CraftNet v1 using one Central Server, one ISP, Home and Farm Customer Routers, overlapping customer addresses, multiple Computers, and one External Application?

## Answer

CraftNet v1 is verified at four levels: cross-language protocol fixtures, deterministic Lua role simulation, Go module and Gateway integration tests, and one scripted in-world acceptance run. The automated levels establish correctness and failure behavior; the in-world run proves that the same packages, modem layout, setup wizards, and Go binary work in Minecraft 1.21.11 with Fabric and CC:Tweaked 1.117.1.

### Canonical reference topology

Every automated suite and the operator run uses these stable fixture values. Secrets are fixture-only values and never reused outside tests.

```text
External Application (Go, http/ws://127.0.0.1:8080 in local acceptance)
└── World: Overworld [world-overworld]
    └── Central Server [central-main]
        └── Acme ISP [isp-acme]
            Provider Allocation: 100.64.0.0–100.64.0.255
            ISP address: 100.64.0.1
            ├── Home [network-home]
            │   Router [router-home], provider 100.64.0.10
            │   Router/DNS/gateway: 192.168.1.1
            │   Pool: 192.168.1.20–192.168.1.39
            │   ├── alex-pc [computer-home-alex], 192.168.1.20
            │   └── wall-display [computer-home-display], 192.168.1.21
            └── Farm [network-farm]
                Router [router-farm], provider 100.64.0.11
                Router/DNS/gateway: 192.168.1.1
                Pool: 192.168.1.20–192.168.1.39
                ├── harvester [computer-farm-harvester], 192.168.1.20
                └── silo-monitor [computer-farm-silo], 192.168.1.21
```

The shared discovery channels are Central/ISP `42000`, ISP/Router `42001`, and Router/Computer `42002`. The deterministic acceptance allocation uses operational channels `42100` for Central–Acme, `42101` for Acme–Home, `42102` for Acme–Farm, `42201` for Home LAN, and `42202` for Farm LAN. Production wizards allocate available operational channels rather than depending on these fixture values.

Names resolve as `alex-pc.home.acme.craft`, `wall-display.home.acme.craft`, `harvester.farm.acme.craft`, `silo-monitor.farm.acme.craft`, and `api.craft`. Home exposes `display.update` on `wall-display`; Farm exposes `harvester.status` on `harvester`. The External Application initially allows `echo`, `time.now`, and a deterministic test operation `test.identity` that returns the verified ancestry without exposing credentials.

Standard Computers are sufficient for every role. Advanced Computers or monitors may improve the setup experience but are not required for correctness. The physical acceptance layout follows the settled modem roles: Ender modems connect Central, ISP, and router WANs; each router has one separate wired or ordinary wireless LAN modem; each end Computer has a compatible LAN modem.

### Automated verification

The repository adds these test surfaces during implementation:

- `spec/protocol/v1/` contains valid and invalid frames, CJ1 encodings, SHA-256 and HMAC vectors, enrollment/session transcripts, Ed25519 JWT examples, size-limit edges, and every stable error. The Lua and Go suites must produce byte-identical canonical output and classification for every fixture.
- Lua unit tests cover identifier/address/name validation, lowest-free address assignment, permanent Address Bindings, hierarchical DNS, exact route maps, Network Status, NAT Flow creation/pairing/expiry, event redaction, revision reconciliation, and rolling-buffer limits.
- A deterministic Lua simulator supplies fake clocks, storage, modems, HTTP/WebSocket, screens, and role links. It runs real `craftnet-core` state transitions and `craftnet-runtime` orchestration without Minecraft, controls delivery order and packet loss, and asserts both results and emitted Traffic Events.
- Go tests cover strict Gateway decoding, credential hashing/revocation, Ed25519 Access Token claims and two-minute expiry, ancestry matching, named-operation policy, command idempotency, topology/traffic projections, retention pruning, migrations, and SQLite transaction rollback. `go test -race ./...` must pass.
- Gateway integration tests start the real Go HTTP/WebSocket server on a temporary port with a temporary SQLite database and connect a simulated Central Server. They verify reconnect snapshots, traffic sequence gaps, request correlation, authentication rejection, and durable command replay.

Tests use public module interfaces. They do not reach into protocol counters, NAT tables, or SQL tables except dedicated adapter/conformance tests. A regression fixture is added for every protocol or routing defect before its fix.

### Required acceptance scenarios

The automated simulator and in-world run execute the same numbered scenarios:

1. **Provision the hierarchy.** Provision the World and Gateway Credential in the Go application; run the Central, ISP, Home, and Farm wizards; consume one-time enrollment tokens; verify the topology exactly matches the fixture and bypass messages are ignored.
2. **Join and configure Computers.** Join four Computers with the correct LAN Password, reject an incorrect password, assign the lowest free addresses, report router/DNS/default gateway, and reconnect each Computer to only its original router identity.
3. **Prove overlapping addressing.** Verify both `alex-pc` and `harvester` own `192.168.1.20` in different Customer Network scopes and that neither binding is overwritten or ambiguous in topology, DNS, routing, NAT, or events.
4. **Resolve names.** Resolve a local short name, a name qualified by Customer Network, a fully qualified `.craft` name, and `api.craft`; reject an unknown name and duplicate hostname with `name_not_found` and `name_conflict`.
5. **Deliver local traffic.** Send `alex-pc → wall-display` and assert the request stays at Home's router, creates no Provider Address flow, reaches only the intended Computer, and emits `delivered_local`.
6. **Route between Customer Networks.** Send Home → Farm `harvester.status`; assert the observed path is source Computer → Home Router → Acme → Central → Acme → Farm Router → harvester, paired NAT Flows are created, and the reply returns to Home's `192.168.1.20`, not Farm's.
7. **Fail closed.** Initiate an unexposed remote operation and receive `inbound_denied`; expire a flow and receive `nat_flow_missing` for its late reply; remove the route and receive `route_not_found`; exhaust a small test pool and receive `pool_exhausted`.
8. **Use the External Application.** Register the device through verified ancestry, obtain a two-minute Access Token, call `test.identity`, and assert the Go result reports the exact World/ISP/network/router/Computer path. Reject a mismatched ancestry, disallowed operation, expired token, direct unauthenticated WebSocket, and token without the Gateway Credential.
9. **Observe operations.** Confirm the B-style topology is primary, Traffic and Incidents are secondary, all devices and outcomes appear, payload and secret fields never appear, and the dashboard becomes stale when the Gateway disconnects.
10. **Disable and recover Farm.** Disable Farm from the dashboard, receive an idempotent command result, observe `network_disabled` for new Farm traffic, verify its durable configuration remains, re-enable it, and communicate again without re-enrollment or address changes.
11. **Disconnect dependencies.** Stop the Go application and prove internal local/cross-network traffic continues while external calls fail `gateway_unavailable`; stop a router and ISP in turn, observe state transitions after the 30-second threshold, and verify bounded automatic reconnection.
12. **Restart every role.** Restart a Computer, each Customer Router, the ISP, Central Server, and Go application. Verify stable identities, addresses, names, routes, statuses, and credentials; fresh sessions/counters; discarded NAT Flows; reconciliation snapshots; and no replay of interrupted ordinary requests.

### Capacity and release thresholds

The reference deployment must complete 1,000 deterministic mixed local, cross-network, and external requests with no wrong-recipient delivery, duplicate terminal result, leaked payload in telemetry, or remaining NAT Flow after advancing beyond the 30-second idle limit. A burst of 64 requests on one immediate relationship is accepted; the 65th concurrent request receives `busy`. A 16 KiB raw-modem frame is accepted when structurally valid and the first byte beyond the limit is rejected with `message_too_large` without fragmentation.

The scale simulator creates four ISPs, 20 Customer Routers per ISP, and 20 Computers per router—1,685 topology entities including the Central Server. Every ISP receives disjoint RFC 6598 allocations; every Customer Network may reuse the same RFC 1918 pool; exact routes and replies remain correct during 10,000 seeded mixed operations. This is the v1 tested scale, not a hard architectural maximum.

Rolling diagnostic buffers never exceed 100 events per router, 500 per ISP, or 2,000 at Central. Traffic batches never exceed 100 events or 128 KiB, the Gateway never exceeds 256 in-flight operations, and a full accepted topology remains below the 2,000-entity protocol limit. After the run, advancing the Go clock and pruning removes events beyond the configured 30-day retention while preserving audit and durable topology state.

The release evidence is a checked-in machine-readable acceptance report containing commit, Minecraft/Fabric/CC:Tweaked versions, Go version, fixture version, scenario results, capacity counts, and links to logs with secrets redacted. A release fails if any required scenario is skipped; environmental skips are permitted in ordinary development CI but not in the release run.
