# CraftNet v0.1.0 — acceptance report

**Status: incomplete.** The automated half of the release gate passes. The
in-world half has not been run, and one scenario is blocked on work that is not
built. This report is checked in in that state deliberately: a release gate that
records what was actually done is worth more than one that waits until it can
say everything passed.

## What this report covers

| | |
|---|---|
| Repository | `brian-nunez/computer-craft` |
| Commit | *fill in at the time of the run* — `git rev-parse HEAD` |
| Version claimed | `0.1.0` |
| Wire version | 1 |
| Database schema | 17 |

Pinned in [`spec/versions.json`](../../../spec/versions.json):

| | |
|---|---|
| Minecraft | 1.21.11 |
| Mod loader | Fabric |
| CC:Tweaked | 1.117.1 |
| Go | 1.27.0 |

The in-world run must confirm these are the versions it actually ran against,
and correct the file if not.

## Automated results

Run from a clean checkout:

```bash
make fmt-check
make test
```

| Suite | Result |
|---|---|
| Lua | **253 tests, 0 failures** |
| Protocol fixture catalog | valid, and regenerating it produces no diff |
| `ccpm` package catalog | valid |
| Go, `-race`, two seeds | all packages pass |

The Lua suite runs on Lua 5.2.4 — the version CC:Tweaked provides — and also
passes on 5.4 and LuaJIT.

## Ticket 14 thresholds

| Threshold | Where it is proved | Result |
|---|---|---|
| 1,000 mixed local, cross-network, and external requests | `scale_test.lua` | pass |
| No wrong-recipient delivery | `scale_test.lua`, `core_property_test.lua` | pass |
| No duplicate terminal result | `scale_test.lua` | pass |
| No payload in telemetry | `scale_test.lua` — a canary token that exists only inside a payload is searched for in every field of every event | pass |
| No NAT Flow past the 30-second idle limit | `scale_test.lua`, `core_property_test.lua` | pass |
| A burst of 64 on one relationship is accepted | `scale_test.lua` | pass |
| The 65th receives `busy` | `scale_test.lua` | pass |
| 16 KiB raw modem frame accepted; one byte past it refused | `protocol_conformance_test.lua`, the fixture catalog | pass |
| 1,685 entities: 4 ISPs, 20 routers each, 20 Computers each | `scale_test.lua` | pass |
| Disjoint RFC 6598 allocations per ISP | `scale_test.lua` | pass |
| Every Customer Network reusing one RFC 1918 pool | `scale_test.lua` | pass |
| 10,000 seeded mixed operations, routes and replies exact | `scale_test.lua` | pass |
| Rolling buffers ≤ 100 / 500 / 2,000 | `scale_test.lua`, `core_property_test.lua` | pass |
| Traffic batches ≤ 100 events and ≤ 128 KiB | `hardening_test.go`, `protocol_test.go` | pass |
| Gateway ≤ 256 in flight | `hardening_test.go` | pass |
| A full topology under the 2,000-entity limit | `scale_test.lua` | pass |
| Retention removes old Traffic Events | `hardening_test.go` | pass |
| Retention preserves audit and durable topology | `hardening_test.go` | pass |

## Milestone 8 gate

| Requirement | Where | Result |
|---|---|---|
| Restart matrix | `restart_matrix_test.lua` — every role in turn and then all of them | pass |
| Role outages | `role_internet_test.lua` | pass |
| Gateway outage | `role_internet_test.lua` | pass |
| Pool exhaustion | `core_scenarios_test.lua` | pass |
| Route removal | `core_scenarios_test.lua` | pass |
| NAT expiry | `core_scenarios_test.lua`, `scale_test.lua` | pass |
| Credential revocation | `role_internet_test.lua` | pass |
| Malformed input corpus | `malformed_corpus_test.lua`, `hardening_test.go` | pass |
| 1,000-request reference load | `scale_test.lua` | pass |
| 1,685-entity / 10,000-operation scale simulation | `scale_test.lua` | pass |
| Migrations from an empty database | `sqlite_test.go` | pass |
| Migrations from the previous release candidate | `migration_test.go` | pass |
| Role snapshots survive the restart matrix | `restart_matrix_test.lua` | pass |
| No wrong-recipient delivery observed | above | pass |
| No unauthorized operation observed | `integration_test.go`, `core_authority_test.lua` | pass |
| No payload-bearing telemetry observed | above | pass |
| No unbounded queue observed | `scale_test.lua` — 64 per relationship, 256 per Gateway | pass |
| No leaked active flow state observed | `scale_test.lua`, `restart_matrix_test.lua` | pass |
| Operator setup documentation | [setup.md](../../operations/setup.md) | written, **not yet followed by a second Operator** |
| Operator recovery documentation | [recovery.md](../../operations/recovery.md) | written, **not yet exercised** |
| All twelve scenarios in the target Minecraft stack | [the checklist](milestone-8-in-world.md) | **not run** |

## Defects found and fixed during this milestone

Every one of these has a regression test that fails without the fix.

**A restarted role could never reconnect to a parent that had not restarted.**
Found by the restart matrix. A role bumped its session generation in memory but
never wrote it down, so a restart began counting from one again. Its parent had
already seen that nonce, refused the repeat as a replay — correctly — and the
child sat there unable to reconnect, with no error that pointed at the cause.
The counter is durable now.
Regression: `restart_matrix_test.lua`, "a session generation is durable across
repeated restarts".

**Correlated requests were unbounded per relationship.** The protocol's Link
refused work past 64 in flight, but the role engines kept opening correlation
records and NAT Flows with no bound at all — so the refusal happened at the wire
while the memory accumulated underneath it. Every role now refuses the 65th with
`busy`, at the layer where the memory would actually have grown.
Regression: `scale_test.lua`, "a burst of 64 is accepted on one relationship and
the 65th is busy".

## What is not proved

**The in-world Gateway transport was built in [Milestone
9](../milestone-9.md).** A Computer names an External Operation with
`external_call` ([ADR
0010](../../adr/0010-name-the-external-application-with-its-own-message-kind.md)),
and the Central Server holds a real `http.websocket` session that opens with
hello, heartbeats, batches traffic, and reconnects under backoff. **Scenario 8
is no longer blocked.**

What it has not done is run. The two ends have still never been one pair of
processes: what proves the path is a stand-in for `craftnetd` on the same seam
the real adapter uses. Scenarios 8, 9, and 10 stand unrun rather than blocked.

**Subordinate roles do not relay Traffic Events upstream.** A Customer Router
and an ISP record their own; nothing carries them to the Central Server. The
traffic **scenario 9** shows will therefore be the Central Server's view. See
[Milestone 9](../milestone-9.md) for why that was left rather than improvised.

**No in-world run has been performed.** Every result above comes from Lua on a
real interpreter and Go under `-race`. None of it has met Ender modems, real
modem range, CC:Tweaked's scheduler, `ccpm` over real HTTP, or a person typing a
token from one screen into another.

**No second Operator has followed the documentation.** The gate says one must be
able to, without editing source. The commands the documentation names all exist
and are checked by `role_programs_test.lua`, but nobody has sat down with only
the guide and built a World from it.

**The dashboard has not been driven in a browser.** See [Milestone 7's
checklist](milestone-7-dashboard.md).

## What has to happen before v0.1.0 is tagged

1. ~~Build the in-world Gateway transport~~ — done in [Milestone
   9](../milestone-9.md). Decide whether shipping v0.1.0 without upstream
   Traffic Event relay is acceptable, or hold the tag for it. That is a
   decision, and it belongs to whoever owns the release.
2. Run [the in-world checklist](milestone-8-in-world.md) from clean Computers
   and a clean data directory, and fill in the results here.
3. Run [the dashboard checklist](milestone-7-dashboard.md).
4. Have a second Operator build a World from [the setup
   guide](../../operations/setup.md) alone.
5. Stamp the release: `bash scripts/build-release.sh 0.1.0`, check the
   `SHA256SUMS` it writes, tag `v0.1.0`, and archive this report at that commit.

Until then this repository is at `0.1.0-dev`, and every binary it builds says so.
