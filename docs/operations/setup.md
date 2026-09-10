# Setting up CraftNet

This is the whole procedure, from nothing to a working World. Follow it in
order. You should not have to read any source code, and if you do, that is a
defect in this document — say so.

You will need: a Minecraft server with CC:Tweaked, eight Computers, and one
machine that can run `craftnetd` and reach the internet (or a copy of the Lua
packages, if it cannot).

## What you are building

One **World**, containing one **Central Server**, one **ISP**, two **Customer
Networks**, and four **Computers**.

```text
craftnetd ── Gateway ── Central Server
                             │
                            Acme (ISP)
                          ┌──┴──┐
                       Home     Farm
                      ┌──┴──┐  ┌──┴──┐
                 alex-pc  wall  harv  silo
                       display  ester  monitor
```

Home and Farm both use `192.168.1.20` onwards. That is not a mistake and it is
not a problem: an address only means something inside its own Customer Network.

## 1. Start the External Application

On the machine that will run it:

```bash
craftnetd provision -world world-overworld -central central-main \
  -gateway-url ws://YOUR-HOST:8080/gateway
```

It prints five values **once**:

```text
World identity            world-overworld
Central Server identity   central-main
External Application URL  ws://YOUR-HOST:8080/gateway
World Key                 <64 hex characters>
Gateway Credential        <64 hex characters>
```

**Write them down now.** The application keeps only digests and genuinely
cannot print them again. If you lose them, see
[Recovery](recovery.md#i-lost-the-provisioning-bundle).

Add yourself as an Operator, then start it:

```bash
craftnetd operator -name YOUR-NAME      # it asks for a password on stdin
craftnetd serve -listen 0.0.0.0:8080
```

Behind TLS, add `-secure-cookies`. The dashboard is at the address it prints.

### Let the Central Server reach it

The Central Server opens the Gateway with CC:Tweaked's HTTP API, so that has to
be on and the host has to be allowed. In the CC:Tweaked server config:

```toml
[http]
enabled = true

[[http.rules]]
host = "YOUR-HOST"
action = "allow"
```

If the API is off or the host is blocked, everything in world still works —
addressing, names, routing, NAT, Network Status. External calls give
`gateway_unavailable`, and the dashboard shows the World as stale.

> The password is read from standard input rather than from a flag, because a
> flag is visible in your shell history and in the process list of everyone else
> on that machine.

## 2. Physical layout

| Computer | Role | Modems |
|---|---|---|
| 1 | Central Server | one Ender modem |
| 2 | Acme (ISP) | one Ender modem |
| 3 | Home router | one Ender modem (to the ISP) and one wired or wireless modem (to its LAN) |
| 4 | Farm router | the same pair |
| 5–6 | `alex-pc`, `wall-display` | one LAN modem each, in range of Home only |
| 7–8 | `harvester`, `silo-monitor` | one LAN modem each, in range of Farm only |

Ender modems are what connect Central, the ISP, and each router's uplink. Each
router's LAN is a separate, ordinary modem: that separation is what makes a
Customer Network a Customer Network.

## 3. Install the packages

On each Computer:

```lua
ccpm install craftnet-central     -- Computer 1
ccpm install craftnet-isp         -- Computer 2
ccpm install craftnet-router      -- Computers 3 and 4
ccpm install craftnet-computer    -- Computers 5 through 8
```

Each of those pulls in `craftnet-protocol`, `craftnet-core`, and
`craftnet-runtime` on its own.

## 4. The Central Server

On Computer 1:

```lua
setup
```

It asks for the five values you wrote down in step 1. Then:

```lua
startup
```

The screen shows the World identity, its connectivity, and the last error, if
there was one. Leave it running.

To put an ISP on CraftNet, ask the Central Server for a token:

```lua
token
```

It prints a **one-time ISP Enrollment Token**: sixteen characters in four
groups, short enough to read off one screen and type into another. Nobody stores
it; the Central Server remembers only that it was spent.

## 5. The ISP

On Computer 2:

```lua
setup
```

It asks for the ISP identity (`isp-acme`), its name (`acme`), and the token from
step 4. When it succeeds it prints the **Provider Allocation** the Central
Server gave it — a block of RFC 6598 addresses that is this ISP's and no other
ISP's. Then:

```lua
startup
```

To put a Customer Network on CraftNet, ask the ISP for a token:

```lua
token
```

That is a **Router Enrollment Token**, and it works the same way.

## 6. The Customer Routers

On Computer 3 (Home):

```lua
setup
```

It asks for:

- the router identity (`router-home`) and the network's name (`home`)
- the router's own address on its LAN (`192.168.1.1`)
- the address pool to hand out (`192.168.1.20` to `192.168.1.39`)
- a **LAN Password** — the one thing Computers on this network will need

That is a complete, working Customer Network. It just cannot be reached from any
other one yet. Putting it on CraftNet is a separate, deliberate step:

```lua
uplink
```

It asks for the ISP's name (`acme`) and the Router Enrollment Token from step 5,
and prints the Provider Address the ISP assigned. Then:

```lua
startup
```

Repeat all three on Computer 4 with `router-farm`, `farm`, and a *second* token
— a token is one-time, so Farm needs its own.

Use the same address pool for both networks. Overlap is the point.

## 7. The Computers

On each of Computers 5 to 8:

```lua
setup
```

It asks for a hostname, the Customer Network's name, and that network's LAN
Password. The router assigns the lowest free address and tells the Computer its
address, its router, its DNS, and its default gateway. Nothing is typed twice.

Then `startup`.

At this point `alex-pc` and `harvester` both hold `192.168.1.20`, in different
Customer Networks, and neither is ambiguous.

## 8. Publish a service

A Computer is reachable from *its own* Customer Network as soon as it joins.
Reaching it from another one is a deliberate act. On Farm's router (stop
`startup` first, or use a second shell tab on an Advanced Computer):

```lua
expose harvester harvester.status
```

`expose` on its own lists what is published. `expose -r harvester
harvester.status` withdraws it again. Nothing else on the network is reachable
from outside. That is the default, and it is the right one.

## 9. Check it

From `alex-pc`:

```lua
craftnet status
craftnet resolve harvester.farm.acme.craft
craftnet call harvester.farm.acme.craft harvester.status
craftnet call api.craft test.identity
```

`craftnet status` prints this Computer's address, network, router, DNS, ISP, and
full `.craft` name. Names widen a label at a time: `harvester` works from inside
Farm, `harvester.farm` from anywhere on Acme, and the full form from anywhere in
the World.

`craftnet call api.craft test.identity` is the External Application. It reports
the World, ISP, Customer Network, Customer Router, Computer, and address the
call actually arrived on — verified at every hop, never claimed. The first call
from a Computer registers it and gets it a token; you do not do either by hand.

Then open the dashboard. You should see the whole World: the ISP with its
allocation, both Customer Networks with their Provider Addresses, and all four
Computers with their addresses — including the two that share one.

## Where things are

| What | Where |
|---|---|
| Each Computer's durable state | `state/<role>.json` on that Computer, with a backup beside it |
| Secrets in world | a separate secret store on the same Computer, never in the snapshot |
| Everything the External Application knows | one SQLite file, `data/craftnet.db` by default |
| Traffic Events | that database, kept 30 days by default (`-retention`) |
| Audit history | that database, kept forever |

## The complete command set

Nothing below needs a file edited or a value looked up in source.

| Computer | Command | What it does |
|---|---|---|
| Central Server | `setup` | Take the provisioning bundle |
| | `token` | Issue a one-time ISP Enrollment Token |
| | `startup` | Run it |
| ISP | `setup` | Configure it and spend an ISP token |
| | `token` | Issue a one-time Router Enrollment Token |
| | `startup` | Run it |
| Customer Router | `setup` | Configure the network and its LAN Password |
| | `uplink` | Spend a Router token and join CraftNet |
| | `expose` | Publish or withdraw a Computer's service |
| | `revoke` | Take a Computer off this network |
| | `startup` | Run it |
| Computer | `setup` | Join a Customer Network with its LAN Password |
| | `craftnet status` | What this Computer is and where |
| | `craftnet resolve NAME` | Turn a CraftNet Name into a scoped address |
| | `craftnet call NAME SERVICE` | Call a service and print what comes back |
| | `craftnet call api.craft OPERATION` | Call the External Application |
| | `startup` | Run it |
| The Go machine | `craftnetd provision` | Create a World and print its bundle once |
| | `craftnetd operator` | Add, re-password, disable, or list Operators |
| | `craftnetd serve` | Serve the Gateway and the dashboard |
| | `craftnetd version` | Report the build, wire, and schema versions |

## Next

- [Recovery](recovery.md) — when something breaks.
- [The dashboard](../../README.md#the-dashboard) — what the three views are for.
