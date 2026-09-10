# craftnet-computer

A Computer on a Customer Network. Install this on the turtles and terminals that
should be able to talk.

```
ccpm install craftnet-computer
```

**Version 0.1.0 · wire version 1 · depends on `craftnet-runtime` ^0.1.0**

## What it is

The end of the hierarchy, and the role that owns the least. It joins a Customer
Network once, remembers what its router told it, and reconnects with its own
credential from then on.

**It decides nothing about the network.** Its Customer Router stays authoritative
for membership and for the address; this role only remembers what it was given,
and shows it while the router is unreachable.

## Programs

| | |
|---|---|
| `setup` | join a Customer Network with its LAN Password |
| `craftnet` | `status`, `resolve NAME`, `call NAME SERVICE`, `call api.craft OPERATION` |
| `startup` | run it |

The LAN Password is used exactly once, at join, and never stored. What is kept
is a durable LAN Credential of this Computer's own.

```
craftnet status
craftnet resolve harvester.farm.acme.craft
craftnet call harvester.farm.acme.craft harvester.status
craftnet call api.craft test.identity
```

## Names

A short name resolves inside this Computer's own Customer Network; a longer one
widens a label at a time:

```text
harvester                    here
harvester.farm               anywhere on this ISP
harvester.farm.acme          anywhere in the World
harvester.farm.acme.craft    explicit
```

`api.craft` is the one name that is not a Computer. It has **no address** — the
External Application is reached through a named operation and the ancestry every
hop derived, never by routing to it — so `resolve` answers it without a lookup
and DNS refuses to invent one.

## Talking

Every request goes to the Customer Router, local or not. There is no subnet mask
and no direct Computer-to-Computer path, so a call to the machine beside you
takes the same road as a call across the World — it just does not go far.

To serve requests, pass an `application` table to `new`: a map of service name to
handler. A service nobody implemented simply goes unanswered, which the caller
sees as a timeout rather than as a false success. Nothing is reachable from
another Customer Network until that network's router runs `expose`.

## The External Application

```lua
local payload, code, problem = computer:call("test.identity", protocol.object())
```

`call` is the whole path as one thing. On first use it registers this Computer
through its verified CraftNet ancestry — there is no secret to present, because
every hop between here and the Central Server derived who is asking rather than
believing it — keeps the Device Credential in the secret store, exchanges it for
a two-minute Access Token, and makes the call.

It holds that token until it is nearly spent, **measured as a duration** from the
protocol's own constant rather than against a wall clock, and drops it if it is
ever refused as expired. The token is opaque here: CraftOS never reads a claim
out of one.

When the External Application is unreachable, the answer is
`gateway_unavailable` and everything in world carries on unchanged.

## Surface

`new{path, adapters, application?, computer_number?}` returns a Computer.

| | |
|---|---|
| `start`, `run`, `serve`, `tick` | lifecycle |
| `joinNetwork{password, hostname, …}` | join once |
| `connect`, `establish`, `isJoined` | reconnect with the durable credential |
| `resolve(name)` | a CraftNet Name to a scoped address |
| `request(destination, service, payload)` | call another Computer |
| `call(operation, payload)` | call the External Application, registering and getting a token as needed |
| `externalCall`, `registerDevice`, `accessToken` | the three steps of that, separately |
| `await{timeout_ms?, attempts?}` | serve until the answer arrives |
| `state`, `lines` | what it was told, and what the screen shows |

## Rejoining

A Computer that has joined before returns **only to the router identity it
joined** — never to another network that happens to share a name or a password.
It names the identity that router already knows, so it comes back to the same
address instead of being treated as new.

Its session generation counter is durable. That is what makes each reconnect's
nonce different from the last, and a Computer that lost it would be refused as a
replay by a router that had not restarted.

Its rolling Traffic Event buffer holds 100.

## Read next

[Setup](../../docs/operations/setup.md) ·
[Recovery](../../docs/operations/recovery.md) ·
[Architecture](../../docs/architecture.md)
