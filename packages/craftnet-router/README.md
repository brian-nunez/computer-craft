# craftnet-router

A Customer Router: the boundary of one Customer Network, and the only role that
sees a Computer.

```
ccpm install craftnet-router
```

**Version 0.1.0 · wire version 1 · depends on `craftnet-runtime` ^0.1.0**

## What it is

One per Customer Network — Home, Farm, whatever you build. It owns its RFC 1918
pool and its Address Bindings, local DNS, which of its Computers are reachable
from elsewhere, and the NAT Flows that let a reply find its way home.

Every Computer's traffic passes through it, which makes it the place where **who
is asking stops being a claim and becomes a fact**: it rebuilds `source` from
the authenticated session rather than believing what the Computer wrote, so a
Computer cannot pose as its neighbour.

A Customer Network works perfectly well with no ISP at all. Local names resolve,
local requests are delivered, nothing leaves. `uplink` is what makes it
reachable from another one.

## Programs

| | |
|---|---|
| `setup` | choose the network name, the pool, the LAN Password, and the channels |
| `uplink` | enroll with an ISP using a Router Enrollment Token |
| `expose` | publish or withdraw a Computer's service; on its own, list what is published |
| `revoke` | take a Computer off the network; on its own, list who is on it |
| `startup` | run it |

A LAN Password is at least 8 characters and is never stored — a Computer proves
it once at join and gets a durable credential of its own.

## Channels

| | |
|---|---|
| 42001 | where it finds its ISP |
| 42002 | where its Computers discover it |

Upstream is an Ender modem to the ISP; downstream is one wired or wireless LAN.

## Addresses

The pool is a first and last address — no subnet mask, because every Computer
sends through the router anyway
([ADR 0005](../../docs/adr/0005-use-network-scoped-addresses-without-subnets.md)).

**A binding is permanent.** A Computer that restarts gets the same address back;
the router never evicts one Computer to make room for another, so an exhausted
pool is an answer (`pool_exhausted`), not a reason to reuse. Freeing one is
`revoke`, and it is an Operator's decision.

Home and Farm can both hand out `192.168.1.20`. That is the point: an address
means something only inside its own Customer Network.

## Traffic

**Local stays local.** A request from one Computer to another on the same
network is delivered by the router with no NAT Flow, no Provider Address, and
nothing leaving.

**Remote leaves through the ISP** — always, even for a Customer Network on the
same ISP, because the Central Server is the only interconnection point. The
router opens a NAT Flow and sends its identifier along; the reply carries it
back, and **the flow, never the address, is what says which Computer asked**
([ADR 0006](../../docs/adr/0006-use-paired-flows-for-simplified-nat.md)).

**Inbound is denied by default.** A remote request reaches a Computer only if
`expose` published that exact service. Everything else is `inbound_denied`
before it ever gets there.

**An external call is NATted like any other remote request** but names no
Customer Network — the External Application is not one. See
[ADR 0010](../../docs/adr/0010-name-the-external-application-with-its-own-message-kind.md).

## Admission

A LAN Password is gameplay-grade, so what must not be free is guessing at it.
Failures are counted per claimed identity **and** across the whole LAN, because
an attacker rotating identities would otherwise slip past a per-identity limit.
A throttled caller is refused with the same code a wrong password gives — it
learns nothing from being told it is being throttled.

Nothing durable changes on a failure: an Operator should not have to clear a
counter to let a Computer back in.

## Surface

`new{path, adapters, …}` returns a Customer Router.

| | |
|---|---|
| `start`, `run`, `serve`, `tick` | lifecycle |
| `configure(settings)` | apply the wizard's answers |
| `enrollUpstream`, `connectUpstream` | joining and rejoining its ISP |
| `changePassword`, `revoke` | LAN administration |
| `state`, `lines` | authoritative state, and what the screen shows |

`lan` is the join listener; `wizard` holds the setup questions and their
validation.

An ISP owns some of a router's configuration — its `customer_network_id`,
`customer_network_name`, `isp_id`, and `provider_address` — and **nothing else**.
A snapshot from upstream naming this router's own pool is not merged and not
obeyed.

Its rolling Traffic Event buffer holds 100.

## Read next

[Setup](../../docs/operations/setup.md) ·
[Recovery](../../docs/operations/recovery.md) ·
[Architecture](../../docs/architecture.md)
