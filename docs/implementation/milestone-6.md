# Milestone 6 — Go External Application and Gateway

Status: complete on 2026-09-09, with one deliberate deferral — see
[Deliberately deferred](#deliberately-deferred).

Milestone 6 builds `craftnetd`: one process, one SQLite file, one origin, and
one Gateway Session per World. It is where a Computer stops being only an
in-world thing and gets an identity outside Minecraft.

## Delivered

| Module | Owns |
|---|---|
| `store` | One cohesive transactional interface, with an in-memory and a SQLite adapter held to the same suite |
| `store/sqlite` | Forward-only migrations, CGo-free driver, one writer |
| `identity` | World provisioning, hashed credentials, Ed25519 Access Tokens, exact ancestry |
| `operations` | The named-operation allowlist and its policies |
| `gateway` | One live session per World, ingestion, correlation, idempotent commands |
| `worldview` | Topology, traffic, incident, presence, and staleness projections; retention |
| `web` | `net/http` routing and the WebSocket adapter |
| `app` | The composition root, and the only place an operation is registered |

`craftnetd` has three subcommands: `provision`, `serve`, and `version`.

### The operations this release allows

`device.register`, `token.issue`, `echo`, `time.now`, and `test.identity`.
Anything else is `forbidden_operation` — an empty allowlist is the right
default, and adding to it is a handler plus a policy at the composition root,
not a new route or a new message family.

## Gate evidence

`make fmt-check` and `make test` pass. 210 Lua tests and the Go suite under
`-race`, at two seeds.

| Gate requirement | Evidence |
|---|---|
| Unit and race tests against in-memory and SQLite adapters | `storetest` is one suite; both adapters run it, including rollback |
| Gateway authentication | no credential, wrong credential, another Central Server, revoked credential — all refused |
| One live session per World | a second connection takes over rather than running alongside |
| Reconnect snapshots | the welcome reports the topology revision and traffic sequence already held |
| Sequence-gap staleness | a gap is recorded as an audit note and the surviving events are still stored |
| Command idempotency | the same Command ID returns the result already applied |
| Two-minute token expiry | a token is refused one second past its life |
| Exact ancestry matching | a valid token from another Customer Network is refused |
| Allowlist rejection | an unregistered operation is `forbidden_operation` |
| Database rollback | a failed transaction leaves no credential, event, or audit record |
| Scenario 8 end to end | register, token, `test.identity`, and the verified path reported back |
| Stopping the Go process | `role_internet_test.lua` — scenarios 5 and 6 still work; external calls give `gateway_unavailable` |

The Gateway tests run a real `httptest` server and a real WebSocket client, not
a stand-in. What the tests drive is the same handler `craftnetd serve` mounts.

## Decisions made inside this milestone

- **A secret is never stored in the clear.** The database keeps a SHA-256 digest
  of a World Key, a Gateway Credential, and a Device Credential, and nothing
  more. A database that leaks tells an attacker nothing it can present. A test
  asserts it directly rather than trusting the code to have meant it.
- **An unknown World and a wrong secret are indistinguishable.** Both come back
  `authentication_failed`, so probing for World identities learns nothing.
- **A token the application never issued fails closed.** Verification treats an
  unrecognised `jti` as revoked. A signature alone is not enough when the
  application cannot say it issued the thing.
- **Re-registering a device issues a fresh credential and keeps the identity.**
  A Computer that lost its credential recovers without an Operator deleting
  anything. A Computer that turns up from a *different* ancestry is refused
  rather than quietly rewritten.
- **A newer Gateway connection takes over.** A Central Server that reconnected
  is the one that is really there. The older socket is closed rather than left
  racing it.
- **A sequence gap is recorded, never filled.** Missing Traffic Events are
  written into the audit trail as a gap, and the events that did arrive are
  still stored. The dashboard will show the hole rather than a plausible
  present.
- **A replayed older topology is ignored.** A reconnecting Central Server may
  resend; going backwards would make the projection lie.
- **Retention prunes telemetry and never the audit trail.** Losing the record of
  a decision to a retention window is a different kind of mistake from losing a
  Traffic Event, and the store suite asserts the difference.
- **`craftnetprov` was removed.** Milestone 1 built it to unblock development
  before a database existed; `craftnetd provision` supersedes it. Keeping both
  would have been a trap — provisioning with the old one produced a bundle the
  Gateway would then refuse, because nothing had been recorded to check against.
  The Central Server wizard now points at `craftnetd provision`.

## Deliberately deferred

**The in-world leg of the external path is not built, and it needs a decision
the tickets do not settle.**

> Settled in [Milestone 9](milestone-9.md): a Computer names an External
> Operation with its own message kind, `external_call`. See [ADR
> 0010](../adr/0010-name-the-external-application-with-its-own-message-kind.md).

Ticket 9 says a Computer's External Operation travels "through its complete
CraftNet ancestry", and `external_request.body` carries a `source_flow_id` —
which means the request passed through a Customer Router's NAT. But ticket 16
fixes `service_request.destination` as `{customer_network_id, computer_id? |
address?}`, and the External Application is not a Customer Network. There is no
in-world destination form that names it.

Rather than invent one at the end of a large milestone, this is left open. What
exists is the Central Server end: an `external_request` input that stamps the
ancestry from the route directory — never from anything a caller wrote — emits a
Gateway effect, and fails with `gateway_unavailable` when there is no session.
The Go side is complete and tested from the Gateway inward.

The missing piece is how a Computer says "call this External Operation" on the
in-world wire. It wants deciding properly, with the same care the rest of the
protocol got.

Other deferrals:

- The Operator dashboard is Milestone 7. What exists is a small read-only JSON
  surface and `/healthz`; there is no cookie session, no login, and no UI.
- `device.rotate` is named in ticket 16's credential rules but not registered:
  re-registering already covers recovering a lost credential.
- No in-world acceptance run is required by this gate, and none was performed.
  Milestone 5's checklist still stands unrun.

Milestone 7 is the next implementation gate: the embedded dashboard, cookie
sessions, the topology canvas, and confirmed Enable/Disable with audit history.
