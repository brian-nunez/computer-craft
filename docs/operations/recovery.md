# Recovering CraftNet

Things that go wrong, and what to do about them. Each one names what you will
actually see, because a symptom you can match is worth more than a cause you
have to guess at.

Two principles run through all of it:

- **Nothing recovers by replaying an ordinary request.** If a call was
  interrupted, it is gone. CraftNet will not decide on its own to do again
  something a player asked for once.
- **Durable configuration survives almost everything.** Identities, addresses,
  names, routes, statuses, and credentials are written down. Sessions, counters,
  and NAT Flows are not, and are meant not to be.

## A role will not start

```text
CraftNet Central cannot start: storage_unavailable ...
The snapshot could not be read. Nothing has been overwritten.
```

Every role keeps two copies of its state — a primary and a backup — each with a
SHA-256 digest. On start it reads the primary, checks the digest, and falls back
to the backup if the primary is damaged. Seeing this message means **both** were
unreadable.

It has deliberately not overwritten anything. Look in `/craftnet/` on that
Computer: you will find the snapshot and its backup. If you have an older copy
of either, put it back and start again.

If you have neither, that role has to be provisioned again, and what that costs
depends on which role it was — see [Starting a role over](#starting-a-role-over).

## A role starts but never connects

The screen shows `connecting` and stays there, or shows `disconnected`.

1. **Is its parent running?** A Computer needs its router; a router needs its
   ISP; an ISP needs the Central Server. Start from the top.
2. **Are the modems right?** Central, the ISP, and each router's uplink need
   Ender modems. Each router's LAN is a *separate* modem, and its Computers need
   to be in range of that one.
3. **Wait 30 seconds.** A relationship is only declared disconnected after 30
   seconds of silence, and reconnection backs off from one second to thirty. It
   retries on its own; it does not need help.

A role that says `revoked` will not retry, and should not: its credential was
destroyed deliberately. See [A Computer was
revoked](#a-computer-was-revoked-and-needs-to-come-back).

## The dashboard says a World is stale

```text
This World has no live Gateway Session. Everything below is the last thing it
reported, not what is happening now.
```

The Central Server is not connected to `craftnetd`. **Everything in world keeps
working**: local traffic, cross-network traffic, DNS, and routing never needed
the External Application. Only External Operations fail, with
`gateway_unavailable`.

Check, in this order:

1. `craftnetd serve` is running and reachable at the URL the Central Server was
   given.
2. CC:Tweaked's HTTP API is enabled and that host is allowed — see
   [Setup](setup.md#let-the-central-server-reach-it). A blocked host looks
   exactly like a stopped application from in world.
3. The Gateway Credential the Central Server holds is the one this World was
   provisioned with. A wrong one is refused, not retried into working.

The Central Server reconnects on its own, under backoff, up to every 30 seconds.
Restarting it is not usually necessary; it will not hurt.

What the dashboard shows meanwhile is the last thing that World reported. It is
not wrong; it is old, and it says so.

## A call fails

Every failure has one stable code. Match it here rather than guessing.

| Code | What it means | What to do |
|---|---|---|
| `name_not_found` | No Computer answers to that name | Check the spelling and the scope. `craftnet status` prints this Computer's full name; work back from that shape. |
| `name_conflict` | Two Computers claim one hostname | Rename one. A hostname is unique inside its Customer Network, not the World. |
| `inbound_denied` | Reachable, but that service is not published | On the destination's router: `expose HOSTNAME SERVICE`. |
| `route_not_found` | The Central Server has no route to that network | The destination's router has not enrolled, or its route was removed. Run `uplink` there. |
| `network_disabled` | An Operator disabled that Customer Network | Re-enable it from the dashboard. Nothing was lost; it needs no re-enrollment. |
| `nat_flow_missing` | The reply came back after the flow expired | The call took longer than 30 seconds. Try again; nothing is broken. |
| `pool_exhausted` | Every address in the pool is bound | See [The address pool is full](#the-address-pool-is-full). |
| `busy` | 64 requests are already outstanding on one relationship | Wait. This is a bound, not a fault: work past it is refused rather than queued. |
| `router_unavailable` | The Computer is not connected to its router | Start the router, or see [A role starts but never connects](#a-role-starts-but-never-connects). |
| `upstream_unavailable` | A router or ISP cannot reach its parent | Same, one level up. |
| `gateway_unavailable` | `craftnetd` is not connected | See [The dashboard says a World is stale](#the-dashboard-says-a-world-is-stale). |
| `authentication_failed` | The credential was wrong, or came from the wrong place | A credential is checked against the exact path it arrived on. A valid one presented from another Customer Network is refused, on purpose. |

## The address pool is full

```text
pool_exhausted
```

Every address between the pool's first and last is bound. An Address Binding is
**permanent** — a Computer that reconnects gets the address it already had, and
nothing is ever evicted automatically to make room. That is deliberate: an
address quietly changing under a running Computer is worse than a join failing.

Your options, in order of preference:

1. **Free one.** On the router: `revoke HOSTNAME` for a Computer that is gone.
   Its address returns to the pool immediately.
2. **Widen the pool.** Run `setup` on the router again and give a larger range.
   Existing bindings are kept.

`revoke` on its own lists every Computer on the network with its address, which
is usually enough to see which one is no longer there.

## A Computer was revoked and needs to come back

Run `setup` on that Computer and give it the LAN Password again. It gets a new
LAN Credential and whatever address is lowest and free at that moment — which
may not be the one it had.

If it has to keep its old address, revoke nothing else in the meantime: the
lowest free address is exactly the one that was just released.

## I lost the LAN Password

Run `setup` on the router again and set a new one. Every Computer that has
already joined is unaffected — they hold LAN Credentials, not the password, and
a credential is what they authenticate with from then on.

Only a Computer joining *afterwards* needs the new password.

## I lost the provisioning bundle

The World Key and Gateway Credential are stored as digests. Nothing can print
them again — not `craftnetd`, and not the database.

If the Central Server is still running, **nothing is wrong**: it holds its copy
and will keep reconnecting. You have lost the ability to provision that Central
Server again, not the running World.

If you also lost the Central Server's state, provision a new World:

```bash
craftnetd provision -world world-overworld-2 -central central-main
```

Then run `setup` on the Central Server with the new bundle. Its ISPs and their
routers have to enroll again, because the credentials they hold were issued by a
Central Server that no longer exists.

## I lost my dashboard password

On the machine running `craftnetd`:

```bash
craftnetd operator -name YOUR-NAME     # sets a new one
```

There is no reset link and no recovery question: whoever can run that command on
that machine is already the administrator of it.

To see who can sign in, and to stop someone:

```bash
craftnetd operator -list
craftnetd operator -name SOMEONE -disable
```

Disabling ends what they can do at their next request. Their audit history is
untouched: what they did stays recorded.

## Starting a role over

What it costs depends on the role. In every case, install the package again and
run `setup`.

| Role | What has to be done again | What is lost |
|---|---|---|
| Computer | `setup` with the LAN Password | Its address, if another Computer took it meanwhile |
| Customer Router | `setup`, then `uplink` with a fresh Router Enrollment Token | Every Address Binding on that network; its Computers all have to rejoin |
| ISP | `setup` with a fresh ISP Enrollment Token | Its Provider Allocation; every router on it has to enroll again |
| Central Server | `setup` with a *new* provisioning bundle | The whole World's route directory; every ISP has to enroll again |

This is why the Central Server's snapshot is the one worth copying somewhere
else occasionally. It is a small file.

## Upgrading

`craftnetd` migrates its database forward at every start. Migrations are
forward-only and safe to run again, so an upgrade is: stop it, replace the
binary, start it.

```bash
craftnetd version      # reports the build, wire, and schema versions
```

Downgrading is not supported. Copy the database file before an upgrade if you
want the option.

In world, `ccpm install` a newer package version and restart that role. A role's
snapshot migrates forward the same way.

## Nothing here matches

Two things worth reading before asking anyone:

- **The role's own screen.** Every role shows its identity, its connectivity,
  and the last error it hit. That last line is usually the answer.
- **The dashboard's Incidents view.** It is the failures, and only the failures,
  grouped by what went wrong and ordered by how often. Select a node in Topology
  first and it will be scoped to that node.
