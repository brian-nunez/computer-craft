# Milestone 8 — the twelve acceptance scenarios in Minecraft

This is the v1 release gate's in-world half, and it has **not** been run.

Everything below is automated somewhere in this repository, against real role
packages, a real runtime, real links, the real protocol, and a real HTTP and
WebSocket server. What this run adds is the parts no test can supply: Ender
modems and real range, the `fs` and `term` adapters, `ccpm` over real HTTP,
CC:Tweaked's own scheduler, and a person typing tokens from one screen into
another.

Start from **clean Computers and a clean Go data directory**. A run on top of
existing state proves the wrong thing.

## Before you start

Follow [the setup guide](../../operations/setup.md) exactly, and note anything
you had to work out for yourself — a step that needed guessing is a finding,
even if the World comes up.

Record, before anything else:

```bash
craftnetd version
git rev-parse HEAD
```

and the Minecraft, loader, and CC:Tweaked versions from
[`spec/versions.json`](../../../spec/versions.json). If any of them differ from
what is pinned there, say so in the report and update the file.

## The reference topology

```text
craftnetd ── Gateway ── Central Server (central-main)
                              │
                          Acme (isp-acme)
                        ┌─────┴─────┐
                   Home             Farm
              (network-home)   (network-farm)
              100.64.0.10      100.64.0.11
                 ┌──┴──┐          ┌──┴──┐
           alex-pc   wall-    harvester  silo-
          .1.20      display   .1.20     monitor
                     .1.21               .1.21
```

Home exposes `display.update` on `wall-display`. Farm exposes
`harvester.status` on `harvester`. Both networks use `192.168.1.20` to
`192.168.1.39`.

---

## 1. Provision the hierarchy

- [ ] `craftnetd provision` prints five values, once.
- [ ] Running it again for the same World is refused rather than reprinting them.
- [ ] The Central Server's `setup` accepts them; `token` prints a 16-character
      token in four groups.
- [ ] The ISP's `setup` spends it and prints a Provider Allocation.
- [ ] The same token, typed again, is refused.
- [ ] Both routers `setup` and `uplink` with their own tokens.
- [ ] The dashboard's topology matches the diagram above exactly.
- [ ] A Computer shouting on the discovery channel with no valid credential is
      ignored — no reply, no log entry that reveals anything.

## 2. Join and configure Computers

- [ ] Four Computers join with the correct LAN Password.
- [ ] A wrong password does not join and binds no address.
- [ ] Repeated wrong passwords are rate limited rather than answered forever.
- [ ] Addresses are `.20` then `.21` in each network, in join order.
- [ ] `craftnet status` on each Computer reports its address, router, DNS, and
      default gateway without being asked twice.
- [ ] Restart a Computer: it reconnects to its own router and no other, with no
      password typed.

## 3. Prove overlapping addressing

- [ ] `alex-pc` and `harvester` both hold `192.168.1.20`.
- [ ] The dashboard shows both, visibly in different Customer Networks.
- [ ] Neither binding was overwritten and neither is ambiguous in topology, DNS,
      routing, NAT, or Traffic Events.

## 4. Resolve names

From `alex-pc`:

- [ ] `craftnet resolve wall-display` — a local short name.
- [ ] `craftnet resolve harvester.farm` — qualified by Customer Network.
- [ ] `craftnet resolve harvester.farm.acme.craft` — fully qualified.
- [ ] `craftnet resolve api.craft` — answered without any lookup at all.
- [ ] `craftnet resolve nobody.farm.acme.craft` — `name_not_found`.
- [ ] Joining a second Computer as `alex-pc` on Home — `name_conflict`.

## 5. Deliver local traffic

- [ ] `craftnet call wall-display display.update` from `alex-pc` succeeds.
- [ ] Home's router shows `delivered_local`.
- [ ] No Provider Address flow was created — the traffic never left Home.
- [ ] `silo-monitor` and `harvester` saw nothing.

## 6. Route between Customer Networks

- [ ] `craftnet call harvester.farm.acme.craft harvester.status` from `alex-pc`
      succeeds.
- [ ] The observed path is `alex-pc → Home → Acme → Central → Acme → Farm →
      harvester`, even though both networks are on one ISP.
- [ ] Paired NAT Flows exist while it is in flight.
- [ ] The reply lands on Home's `192.168.1.20` and not Farm's.

## 7. Fail closed

- [ ] Call an unexposed service on Farm — `inbound_denied`.
- [ ] Let a flow idle past 30 seconds and force a late reply — `nat_flow_missing`.
- [ ] Remove Farm's route and call it — `route_not_found`.
- [ ] Set a two-address pool and join a third Computer — `pool_exhausted`.
- [ ] `revoke` one Computer, then join again — the freed address is reused.

## 8. Use the External Application

- [ ] A Computer registers through its verified ancestry and receives a Device
      Credential.
- [ ] It exchanges that for a two-minute Access Token.
- [ ] `test.identity` reports the exact World, ISP, network, router, Computer,
      and address it arrived on.
- [ ] A token from another Customer Network is refused.
- [ ] An operation that is not on the allowlist — `forbidden_operation`.
- [ ] A token used at 121 seconds — `access_token_expired`.
- [ ] A WebSocket to `/gateway` with no Gateway Credential is refused.
- [ ] A WebSocket to `/gateway` with a browser `Origin` is refused.

From a Computer, the whole of it is:

```
craftnet call api.craft test.identity
```

Registering and getting a token happen underneath, on first use.

> **This scenario became runnable in [Milestone
> 9](../milestone-9.md).** The Central Server now holds a real
> `http.websocket` session to `craftnetd`. It has still never been run against
> the real Go process in the target stack — that is what this checklist is for.
> The Computer needs CC:Tweaked's HTTP API enabled and the External
> Application's host allowed; see [the setup guide](../../operations/setup.md).

## 9. Observe operations

- [ ] Sign in to the dashboard. Nothing is visible before signing in.
- [ ] Topology is the view it opens on, and reads as the primary one.
- [ ] Every ISP, Customer Network, and Computer in the fixture appears.
- [ ] Every outcome from scenarios 5 through 7 appears in Traffic.
- [ ] Incidents shows the failures and only the failures.
- [ ] No payload, token, MAC, or password appears anywhere.
- [ ] Stop the Central Server: within about 30 seconds the dashboard says the
      World is stale, and still shows what it last reported.

## 10. Disable and recover Farm

- [ ] Disable Farm from the dashboard. The confirmation says what will happen.
- [ ] The Central Server answers with an applied command result.
- [ ] New Farm traffic gives `network_disabled`.
- [ ] Farm's router, Provider Address, Computers, and addresses are all still
      shown.
- [ ] Pressing Disable again with the same command is harmless.
- [ ] Re-enable it: traffic resumes with no re-enrollment and no address change.
- [ ] The Audit view shows `network.disable`, your name, and `command.applied`.

## 11. Disconnect dependencies

- [ ] Stop `craftnetd`. Local and cross-network traffic carry on unaffected.
- [ ] External calls give `gateway_unavailable` and nothing else changes.
- [ ] Start it again: the Central Server reconnects on its own.
- [ ] Stop Home's router. Its Computers show `disconnected` after 30 seconds.
- [ ] Watch the retries: they back off from about one second to about thirty,
      and never spin.
- [ ] Start it again: everything reconnects with no password and no token.
- [ ] Stop the ISP. Both networks keep working internally; between them fails.

## 12. Restart every role

Restart each in turn, and after each one check the whole World still works:

- [ ] A Computer
- [ ] Home's router
- [ ] Farm's router
- [ ] The ISP
- [ ] The Central Server
- [ ] `craftnetd`
- [ ] All of them, top down

Then verify:

- [ ] Every identity, address, hostname, route, Network Status, and credential
      survived.
- [ ] Sessions and counters are fresh — nothing resumed a session.
- [ ] No NAT Flow survived.
- [ ] Each role reconciled its configuration with its parent on reconnect.
- [ ] An ordinary request interrupted by a restart was **not** replayed.

## Capacity

The scale simulation runs in Lua, not in Minecraft, and the release notes say
so. What is worth checking in world is that nothing falls over at the reference
size:

- [ ] 100 calls in a row from `alex-pc` to `harvester` all succeed.
- [ ] No Computer's screen shows a growing error.
- [ ] After 30 idle seconds, no role is still holding a NAT Flow.

## What to record

Write the results into
[`report-v0.1.0.md`](report-v0.1.0.md), which already holds the automated half.
Name the exact commit and versions. Redact every secret: a World Key, a Gateway
Credential, a Device Credential, an Access Token, or a LAN Password in a
checked-in report is a finding in its own right.

A scenario that could not be run is recorded as **blocked**, with why. It is
never recorded as passed.
