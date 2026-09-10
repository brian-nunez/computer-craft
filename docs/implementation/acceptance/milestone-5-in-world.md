# Milestone 5 — in-world acceptance run

The simulator half of this gate is automated and runs in CI. This is the other
half: it needs Minecraft, and it has **not** been run yet.

Everything below is proved in `tests/lua/role_internet_test.lua` against the
real role packages, runtime, links adapter, and protocol, with only the modem
replaced by an in-memory air. What this run adds is Ender modems and real
range, the `fs` and `term` adapters, `ccpm` over real HTTP, the Go provisioning
command, and tokens carried between screens by hand.

It assumes [the Milestone 4 run](milestone-4-in-world.md) has already passed.

## Setup

| Computer | Role | Modems |
|---|---|---|
| 1 | Central Server | one Ender modem |
| 2 | Acme ISP | one Ender modem |
| 3 | Home router | one Ender modem (WAN) and one wired or wireless modem (LAN) |
| 4 | Farm router | the same pair |
| 5–6 | `alex-pc`, `wall-display` | a LAN modem each, in range of Home only |
| 7–8 | `harvester`, `silo-monitor` | a LAN modem each, in range of Farm only |

```text
ccpm install craftnet-central     # Computer 1
ccpm install craftnet-isp         # Computer 2
ccpm install craftnet-router      # Computers 3 and 4
ccpm install craftnet-computer    # Computers 5 through 8
```

Generate the World's root secrets outside Minecraft:

```bash
cd external && go run ./cmd/craftnetd provision \
  -world world-overworld -central central-main
```

## Checks

### 1. Scenario 1 — provision the hierarchy

On Computer 1, run `setup` and read the values out of `data/world.json`.

- [ ] It refuses a World Key that is not 64 hexadecimal characters.
- [ ] After provisioning, `startup` shows the World identity.
- [ ] Neither the World Key nor the Gateway Credential appears anywhere in
      `/craftnet/central.json`; only `gateway-credential` as a reference does.

Run `token` on Computer 1. Write the token down.

- [ ] It prints a 16-character token in four groups.

On Computer 2, run `setup`: name `acme`, then the token.

- [ ] It reports an identity, a Provider Allocation from `100.64.0.0/10`, and an
      Operational Channel.
- [ ] Running `setup` again on a third Computer with the **same** token is
      refused, and nothing new appears in the Central Server's registry.
- [ ] The token is accepted with lowercase letters, spaces instead of dashes,
      and `O` typed for `0`.

Run `token` on Computer 2 twice, once per Customer Router. On Computers 3 and 4,
run the Milestone 4 router `setup` (networks `home` and `farm`, LAN channels
`42201` and `42202`, the same pool `192.168.1.20`–`192.168.1.39`), then `uplink`
with each token.

- [ ] Each reports a distinct Provider Address inside Acme's allocation.
- [ ] Each reports a distinct Operational Channel.
- [ ] A Customer Router that has not run `uplink` still serves its own LAN.

- [ ] The Central Server's topology lists one ISP and two Customer Networks,
      matching the reference fixture.

- [ ] A Computer transmitting rubbish on channel `42000` changes nothing.

### 2. Scenario 3 — overlapping addressing across the World

Join the four Computers as in Milestone 4.

- [ ] `alex-pc` and `harvester` both hold `192.168.1.20`.
- [ ] `wall-display` and `silo-monitor` both hold `192.168.1.21`.
- [ ] The two Customer Networks have distinct Provider Addresses at Central.

### 3. Scenario 6 — route between Customer Networks

Expose `harvester.status` on `harvester`. From `alex-pc`, call it.

- [ ] The reply comes back with the right payload.
- [ ] The observed path is `alex-pc → Home → Acme → Central → Acme → Farm →
      harvester`: Acme is visited twice, around Central, even though both
      Customer Networks belong to it.
- [ ] The reply reaches Home's `192.168.1.20` and not Farm's.
- [ ] `wall-display` and `silo-monitor` see no part of it.
- [ ] After the reply, no NAT Flow remains on either router.

### 4. Scenario 7 — fail closed

- [ ] Calling an unexposed service on `silo-monitor` gives `inbound_denied`,
      and `silo-monitor` never sees the request.
- [ ] Withdrawing Farm's route at Acme gives `route_not_found`, and Farm keeps
      every Address Binding.
- [ ] Disabling Farm at the Central Server gives `network_disabled`; every
      durable registration survives; re-enabling restores traffic with no
      re-enrollment and no address change.
- [ ] Stopping the ISP makes its routes unreachable, and neither the route nor
      the allocation is deleted. Starting it again restores traffic.

### 5. Restart

Restart every role in turn: a Computer, both routers, the ISP, the Central
Server.

- [ ] Identities, addresses, names, routes, allocations, and Network Status all
      survive.
- [ ] Each role reconnects with its durable credential; no token or password is
      asked for again.
- [ ] Sessions and counters are fresh; nothing in flight is replayed.

### 6. Multi-ISP

Add a second ISP with a fresh token.

- [ ] Its Provider Allocation does not overlap Acme's.
- [ ] Its routers receive channels that do not collide with Acme's.
- [ ] It cannot register a route for a Customer Network Acme owns.

## Result

| Field | Value |
|---|---|
| Date | |
| Commit | |
| Minecraft / Fabric / CC:Tweaked | |
| Outcome | |
| Notes | |

Anything that fails here is a defect, and a regression fixture goes into
`tests/lua/role_internet_test.lua` before the fix.
