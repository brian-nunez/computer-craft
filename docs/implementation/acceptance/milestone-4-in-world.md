# Milestone 4 — in-world acceptance run

The Milestone 4 gate has two halves. The simulator half is automated and runs in
CI. This is the other half: it needs Minecraft, and it has **not** been run yet.

Everything below has been proved in `tests/lua/role_lan_test.lua` against the
real role packages, the real runtime, the real links adapter, and the real
protocol — with only the modem replaced by an in-memory air. What this run adds
is the modem itself, the `fs` and `term` adapters, `ccpm` over real HTTP, and
the setup wizards as an Operator actually types into them.

Record the result at the bottom and check the box in
[`milestone-4.md`](../milestone-4.md) when it passes.

## Versions

Use the pins in [`spec/versions.json`](../../../spec/versions.json):
Minecraft 1.21.11, Fabric, CC:Tweaked 1.117.1.

## Setup

Five Computers, all within modem range. Standard Computers are enough.

| Computer | Role | Modem |
|---|---|---|
| 1 | Customer Router (Home) | one wired or ordinary wireless modem |
| 2 | `alex-pc` | a compatible LAN modem |
| 3 | `wall-display` | a compatible LAN modem |
| 4 | `kitchen` | a compatible LAN modem |
| 5 | `porch-light` | a compatible LAN modem |

On each Computer:

```text
wget https://raw.githubusercontent.com/brian-nunez/computer-craft/main/ccpm.lua ccpm.lua
```

Then on Computer 1:

```text
ccpm install craftnet-router
```

and on Computers 2 through 5:

```text
ccpm install craftnet-computer
```

## Checks

### 1. ccpm resolves the whole tree on a clean Computer

```text
ccpm list
```

- [ ] Computer 1 lists `craftnet-router`, `craftnet-runtime`, `craftnet-core`,
      `craftnet-protocol`, `networking`, and `peripheral-discovery`.
- [ ] Computers 2–5 list `craftnet-computer` and the same five dependencies.

### 2. The router wizard

On Computer 1, run the router package's `setup` program. Answer:

| Question | Answer |
|---|---|
| Customer Network name | `home` |
| This router's address | `192.168.1.1` |
| First address to hand out | `192.168.1.20` |
| Last address to hand out | `192.168.1.39` |
| LAN channel | `42201` |
| LAN Password | any passphrase of at least 8 characters |

- [ ] Each answer is checked as it is typed, not at the end.
- [ ] Entering `Home`, `8.8.8.8`, or a 5-character password is refused with a
      readable reason, and the question is asked again.
- [ ] Setting the router's own address inside the pool (say `192.168.1.25`) is
      refused at the review step.
- [ ] The review shows `Pool: 192.168.1.20 - 192.168.1.39 (20 Computers)`.

Then start it with the `startup` program.

- [ ] The screen shows `Customer Router: home`, the identity `router-home`,
      the address, and a connectivity line.

### 3. Scenario 2 — four Computers join

On Computer 2, run the computer package's `setup` program. Hostname `alex-pc`,
the correct LAN Password.

- [ ] It reports `address 192.168.1.20`, `router 192.168.1.1`, `dns 192.168.1.1`.

Repeat on Computers 3, 4, 5 with hostnames `wall-display`, `kitchen`,
`porch-light`.

- [ ] They receive `.21`, `.22`, `.23` — the lowest free address each time.
- [ ] A join with a **wrong** password fails, says the password was refused, and
      the router's screen shows no new binding.
- [ ] Trying a wrong password six times in a row stops being answered at all.
      Waiting a minute lets a correct password through again.

Start each Computer with its `startup` program.

- [ ] Each reconnects without being asked for the password again.

### 4. Scenario 2 — restart keeps identity and address

Reboot Computer 2, then reboot the router, then unload and reload the chunk.

- [ ] `alex-pc` comes back with the same hostname, the same address
      `192.168.1.20`, and the same identity.
- [ ] It reconnects with its LAN Credential; the password is never asked for.
- [ ] The router still holds all four Address Bindings.

### 5. Scenario 4 — names resolve

From `alex-pc`, resolve each of these:

- [ ] `wall-display` → `192.168.1.21`
- [ ] `wall-display.home` → the same
- [ ] `WALL-DISPLAY.Home.Acme.Craft` → the same (names are case-insensitive)
- [ ] `ghost` → `name_not_found`
- [ ] `api.craft` → answered as the External Application, with nothing put on
      the wire to find out

- [ ] Joining a fifth Computer with the hostname `alex-pc` is refused with
      `name_conflict`.

### 6. Scenario 5 — local traffic stays local

Expose a service on `wall-display` and call it from `alex-pc`.

- [ ] The reply comes back with the right payload.
- [ ] The router's rolling buffer records `delivered_local`.
- [ ] Nothing is transmitted on any channel other than the LAN channel — check
      with a Computer listening on `42000` and `42001`, which should stay silent.
- [ ] A request addressed to a Computer that is not on the network fails with
      `name_not_found`.

### 7. Both networks reuse the same pool

Build a second Customer Network on the same modem range: another router
Computer, network name `farm`, LAN channel `42202`, the same pool
`192.168.1.20`–`192.168.1.39`, and two Computers named `harvester` and
`silo-monitor`.

- [ ] `harvester` receives `192.168.1.20` and `silo-monitor` receives
      `192.168.1.21` — the same addresses Home already handed out.
- [ ] Neither network's bindings are disturbed by the other.
- [ ] A Computer on Farm cannot reach one on Home: cross-network traffic needs
      an ISP and the Central Server, which arrive in Milestone 5.

## Result

| Field | Value |
|---|---|
| Date | |
| Commit | |
| Minecraft / Fabric / CC:Tweaked | |
| Outcome | |
| Notes | |

Anything that fails here is a defect, and a regression fixture goes into
`tests/lua/role_lan_test.lua` before the fix.
