# Milestone 7 — Operator dashboard and administration

Status: complete on 2026-09-10, with two deliberate deferrals — see
[Deliberately deferred](#deliberately-deferred).

Milestone 7 is where a World becomes something an Operator can look at. One
origin serves the page, its assets, and its API; a cookie holds the session; and
the one thing an Operator can tell a World to do — disable a Customer Network —
travels from a browser to authoritative in-world state and answers back.

## Delivered

### The dashboard

Three views over one selection, embedded in the binary and served from one
origin. Nothing is fetched from a CDN, so it works next to a Minecraft server
with no internet.

| View | Variant | Shows |
|---|---|---|
| Topology | B, primary | The World as a navigable hierarchy: Central Server, ISPs and their Provider Allocations, Customer Networks with their Provider Address and Network Status, and the Computers inside each one with their RFC 1918 addresses |
| Traffic | A | The dense Traffic Event table, with outcome/operation/direction filters and event, failure, and byte counters |
| Incidents | C | The exception queue by outcome, and the timeline of the failures behind it |
| Audit | — | What Operators and Central Servers did, oldest decision first |

Selecting a node in Topology carries into Traffic and Incidents: the inspector's
"See its traffic" and "See its failures" switch view without making anyone find
the same node twice. The filter that does it — *only the selected node* — is a
checkbox, so it can be turned off.

The inspector shows a Customer Network's credential *status* and never a
credential *value*: "held, not shown". That is not a redaction step. A payload,
a token, a MAC, and a password are things a Traffic Event and a topology
projection were never allowed to carry, so there is nothing here to redact.

Enable and Disable go through a confirmation dialog that says what will happen
in both directions — new operations refused, configuration kept, re-enabling
needs no re-enrollment.

### Sign-in

`craftnetd operator` creates, re-passwords, disables, and lists the people who
can sign in. The password is read from standard input, never taken as a flag: a
flag lands in shell history and in the process list of everyone on the machine.

- A password is stored salted and PBKDF2-iterated (SHA-256, 200,000 iterations,
  recorded per operator so raising it later invalidates nothing), never as a
  plain digest.
- A failed sign-in says one thing whichever half was wrong, and a missing
  operator costs the same time as a wrong password, so probing learns nothing.
- The session cookie is `HttpOnly`, `SameSite=Strict`, and `Secure` behind
  `-secure-cookies`. It lives twelve hours.
- Disabling an Operator ends what they can do at their next request, because a
  session is resolved to a live Operator every time rather than trusted alone.
  Their audit history is untouched: what they did stays recorded.

### Administration, end to end

An Operator disables Farm in the browser. The API records the decision, issues
an idempotent Command, and the Gateway delivers it. The Central Server's
`gateway_frame` input applies it through the *same* `set_network_status` handler
an Operator at the Central Server's own terminal would reach — including its
idempotency by Command ID — and answers with a `command_result`, applied or
rejected.

A command that cannot be carried out is still answered. A command with no answer
is one the External Application resends forever under the same Command ID, so
refusing out loud is part of the contract.

## Gate evidence

`make fmt-check` and `make test` pass: **218 Lua tests, 0 failures**, and the Go
suite under `-race` at two seeds.

| Gate requirement | Evidence |
|---|---|
| Reference scenario 9 | `TestScenario9` — the whole fixture appears, both holders of `192.168.1.20` stay distinct, every outcome is in Traffic, only failures are in Incidents |
| Reference scenario 10 | `TestScenario10` end to end over a real WebSocket, and `core_scenarios_test.lua` "scenario 10" for the in-world half |
| The dashboard shows the entire fixture | `TestScenario9` asserts every ISP, router, network, address, and Computer by name |
| All required outcomes | nine outcomes reported and each one found in Traffic |
| Selection carries across views | the shared `selectedOnly` filter; the browser half is [a checklist](acceptance/milestone-7-dashboard.md) |
| Payloads, tokens, MACs, passwords never appear | `assertNoSecret` runs over every endpoint the dashboard reads |
| A disconnected Gateway makes data stale | `TestScenario9` closes the socket and waits for `stale`, and asserts the last topology is still readable |
| Duplicate commands are harmless | the repeat returns the applied result, records no second decision, and `"scenario 10: repeating a Command ID from the Gateway is harmless"` proves the in-world half |
| Disabling Farm rejects new operations but retains configuration | `network_disabled` for new traffic; router, Provider Address, Computers, and addresses all still there |
| Re-enabling restores traffic without enrollment | `"re-enabling over the Gateway needs no re-enrollment"` — the same binding, the same address, traffic resumes |
| HTTP authorization fails closed | every `/api` route, including a path nobody registered, refuses an unauthenticated caller |
| WebSocket origin fails closed | a browser `Origin` cannot open a Gateway Session; the same credential still works without one |

Two further checks earn their place: an expired session is *removed* rather than
merely refused (the removal commits instead of being rolled back with the
refusal), and a state-changing request carrying another site's `Origin` is
refused even though the cookie is already `SameSite=Strict`. A fail-closed check
is worth having twice.

## Decisions made inside this milestone

- **One origin, a cookie, and no CORS.** The page, its assets, and its API are
  all served by `craftnetd`. There is no second origin to guard against and no
  bearer token in local storage for a script to be tricked into handing over.
- **The `/api` catch-all is guarded too.** An `/api` path nobody registered is
  refused rather than falling through to the page, so a route added later cannot
  become reachable by accident.
- **The Content-Security-Policy is `default-src 'self'`.** The page may talk to
  itself and to nothing else. There are no dependencies to compromise either:
  no framework, no CDN, no web font.
- **The password never crosses a command line.** `craftnetd operator` reads it
  from standard input.
- **The decision is recorded before it is sent.** What an Operator asked for
  survives even when the answer does not arrive; a repeat of a Command ID the
  application already holds records nothing new.
- **A rejected command is answered.** `command_result` carries `rejected` and
  the stable catalog code, which is what stops an unresolvable command being
  resent forever.

## Deliberately deferred

**The in-world Gateway transport is still not built.** What Milestone 7 adds is
the Central Server's *meaning* for an inbound frame — `Central:receiveGateway`
and the `gateway_frame` input — and the outbound seam already existed. What is
still missing is the adapter that owns the wire: a CC:Tweaked `http.websocket`
client that opens the session, sends hello, heartbeats, batches traffic, and
reconnects. It belongs with [Milestone 6's open
question](milestone-6.md#deliberately-deferred) about how a Computer names an
External Operation, because both are the same missing piece: the in-world half
of the external path.

Until then, scenarios 9 and 10 are proved in two halves that meet at a defined
seam: the Go side against a stand-in Central Server on a real WebSocket, and the
in-world side against the real engine in the simulator. Neither half is
simulated *internally* — but they have not yet been run as one process pair.

**The browser has not been driven.** Every assertion above is against the API
and the engine. What a person actually sees — variant B reading as primary,
selection carrying visibly between tabs, the confirmation dialog — is
[a checklist](acceptance/milestone-7-dashboard.md), and it has **not** been run.

The in-world acceptance runs for [Milestone 4](acceptance/milestone-4-in-world.md)
and [Milestone 5](acceptance/milestone-5-in-world.md) also still stand unrun.
