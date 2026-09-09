Type: grilling
Status: resolved
Blocked by: 03, 05, 06, 07, 09, 10

## Question

Which state survives ComputerCraft restarts and chunk unloading, how are interrupted exchanges retried or reconciled, and how should players observe and recover from router outages, exhausted pools, missing routes, expired authorization, and gateway disconnection?

## Answer

Every CraftOS role persists its authoritative durable state as a versioned JSON snapshot written atomically through a temporary file and rename. It retains the previous valid snapshot as a single backup. The External Application persists its authoritative state and historical projections transactionally in SQLite. Corrupted-primary recovery may use the last valid backup; recovery when both copies are corrupt remains outside v1.

Durable in-world state includes identities and names, parent relationship configuration and credentials, per-relationship session-generation counters, modem/channel assignments, Provider Allocations and addresses, Address Bindings, DNS records, Route Registrations, Network Status, Exposed Services, and operator-authored policies. Authenticated Sessions, per-session message counters, NAT Flows, pending requests, heartbeats, presence, and diagnostic buffers are ephemeral.

Each authoritative component increments a revision when its durable state changes. On reconnect, a child presents its identity and last accepted parent revision. The parent authenticates it and returns either current configuration, revoked status, or a full replacement snapshot when revisions differ. Each owner wins for the state assigned to it in the authority model; CraftNet does not attempt field-level distributed merges.

Connectivity State progresses through `connecting`, `ready`, `degraded`, `disconnected`, or `revoked`. Roles exchange heartbeats every 10 seconds and consider an upstream relationship disconnected after 30 seconds without authenticated traffic. Reconnection uses bounded exponential backoff from 1 to 30 seconds and establishes a fresh Authenticated Session. The local screen shows role, name, identity, Connectivity State, and the latest actionable error.

In-flight messages and NAT Flows never survive a restart. In-world requests time out after 10 seconds and External Operations after 30 seconds. NAT Flows expire after 30 seconds of inactivity. Requests are not automatically replayed; application code or the Operator may retry with a new Request ID. Idempotent administrative commands are the exception: the External Application retains them as pending and resends the same command ID after gateway recovery until the Central Server reports the applied result.

Failures have explicit outcomes and recovery:

| Condition | Outcome | Recovery |
|---|---|---|
| Router unavailable | `router_unavailable` | Computer reconnects to the same router identity |
| Address pool exhausted | `pool_exhausted` | Operator expands the pool or releases a binding |
| DNS name missing | `name_not_found` | Operator fixes the name or registration |
| Duplicate DNS name | `name_conflict` | Operator chooses a unique name |
| No Central Server route | `route_not_found` | Owning ISP restores its Route Registration |
| Parent link unavailable | `upstream_unavailable` | Child retries its authenticated session |
| NAT Flow expired | `nat_flow_missing` | Caller starts a new request |
| Relationship revoked | `credential_revoked` | Operator explicitly re-enrolls the same identity |
| Access Token expired | `access_token_expired` | Computer requests a new token |
| Gateway disconnected | `gateway_unavailable` | Internal traffic continues; Central Server reconnects |
| Request unanswered | `request_timeout` | Caller decides whether to retry |
| Customer Network disabled | `network_disabled` | Operator re-enables it from the dashboard |

Infrastructure records every failure as a Traffic Event and keeps unsampled rolling buffers: 100 events on a Customer Router, 500 on an ISP, and 2,000 on the Central Server. The External Application stores all received Traffic Events for 30 days by default and prunes them daily; retention is configurable. On gateway recovery, the Central Server uploads its remaining buffer and a complete topology snapshot. Gaps remain visible as periods where the dashboard marks the World stale rather than being fabricated or silently hidden.
