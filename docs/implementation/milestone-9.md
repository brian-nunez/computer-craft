# Milestone 9 — The in-world leg of the external path

Status: **the automated half is complete; the in-world run has not happened.**

This milestone exists because the v0.1.0 gate could not be met. Ticket 15 plans
eight milestones, and Milestone 8 finished all of them — but its gate named one
thing that was not built, and refused to tag a release without it:

> **The in-world Gateway transport does not exist.** [...] It is the same
> missing piece as Milestone 6's open question about how a Computer names an
> External Operation on the in-world wire, and it wants deciding properly
> rather than improvising at a release gate.

That is this milestone. It is one decision and the code that follows from it.

## The decision

A Computer names the External Application with **`external_call`**, an
operational message kind of its own. See
[ADR 0010](../adr/0010-name-the-external-application-with-its-own-message-kind.md)
for why, in full. In short: a `service_request` destination is scoped to a
Customer Network, the External Application is not one, and widening the
destination would have put a form in it that nothing may ever route on.

```
external_call  { source, operation, payload,
                 source_flow_id?, access_token? | device_credential? | registration_nonce? }
```

The answer comes back as an ordinary `service_response`. The reply retraces its
NAT Flow by exactly one rule, whether a Computer or the External Application
answered it.

The wire version stays `1`. Nothing has been released, so there is no deployed
peer to keep compatible.

## Delivered

### The wire

`external_call` is in the Lua and Go schemas, in the operational transport, and
in the shared fixture catalog — three accepted cases and three rejected ones,
including the one that matters most: **an external call that names a
destination is refused**. The form ADR 0010 rejected cannot be smuggled back in
by a caller.

The credential rule that was written twice — once in Lua, once in Go — is now
written once per language and applied to both `external_call` and
`external_request`. A Computer refuses its own mistake three hops before the
External Application would have.

`craftnet-protocol` gained `gateway.lua`: the Gateway envelope, hello, and
welcome, mirroring `external/internal/protocol/gateway.go` field for field. It
validates structure, version, kind against transport, size, and body. It signs
nothing — the Gateway relies on WSS and the session it opened.

### The path

| Role | What it does with an `external_call` |
|---|---|
| Computer | Sends one. Refuses a credential combination the operation does not permit |
| Customer Router | Derives the source from the authenticated session, opens a NAT Flow, forwards up. Refuses one arriving from upstream — the External Application does not call into a Customer Network |
| ISP | Checks the router speaks for its own Customer Network, forwards up. Refuses one arriving from upstream |
| Central Server | Checks the ISP owns the source route, stamps the ancestry from the route directory, puts it on the Gateway |

Nothing a caller wrote decides who it is at any hop. The ancestry that reaches
the External Application is built from the route directory, exactly as it was
before this milestone — the difference is that a Computer can now cause one.

The Central Server gained a **Gateway in-flight table of its own**, bounded at
the protocol's 256 rather than a relationship's 64. A World may legitimately
have far more outstanding to the External Application than any one modem
relationship may have to its neighbour, and the two numbers are no longer able
to be confused for each other.

### The transport

`craftnet-runtime` gained `adapter_gateway.lua`: a real CC:Tweaked
`http.websocket` client, and the only file in CraftNet that reaches for the HTTP
API. It opens the socket with `Authorization: Bearer <Gateway Credential>`,
sends `gateway_hello`, reads `gateway_welcome`, carries frames, heartbeats an
idle session, and reconnects under bounded exponential backoff.

Two things about it are worth stating outright:

**A socket is not a session.** Until the welcome decodes there is no Gateway
Session, and an External Operation offered in that window fails with
`gateway_unavailable` rather than being held.

**One bad frame is not a reason to lose a World.** A frame that does not decode
is dropped with its reason recorded; the session stays up. This is the same
claim `hardening_test.go` already makes about the Go end.

CraftOS delivers websocket events through the same queue as modem messages, so
a Central Server waiting on a modem would have discarded every one of them. The
modem transport now **offers** an event it does not recognise to registered
observers, and the Gateway adapter is one. That is the whole of the change to
the modem transport.

### What the Central Server reports

A session that has just opened is sent the whole topology before anything else
travels on it, so the External Application never places a Traffic Event against
a World it has not been shown. Traffic Events the Central Server observed are
then batched — at most 100 to a batch, sequences durable and strictly
increasing — so a batch lost to a disconnect shows up at the far end as a gap in
the record rather than as a plausible present.

Events accumulate whether or not there is a session, bounded at 2,000. A
stopped External Application costs a Central Server a fixed amount of memory
rather than a growing one.

### What a Computer can now do

`craftnet call api.craft OPERATION`. Underneath, on first use, it registers
through its verified ancestry, keeps the Device Credential in the secret store,
exchanges it for a two-minute Access Token, and makes the call. It holds that
token until it is nearly spent — measured as a duration from the protocol's own
`ACCESS_TOKEN_SECONDS`, never against a Computer's wall clock — and drops it if
it is ever refused as expired.

The registration nonce is derived from the LAN Credential and a durable counter
committed before it is sent, never drawn from `math.random`. It is reached
through `protocol.registration.nonce`, a purpose-named surface, so no key helper
leaks out of the protocol package to get it.

## Decisions made inside this milestone

- **A Gateway send that could not leave is an answer owed in world.** Without
  this a stopped External Application looked to a Computer like silence until it
  timed out. The runtime now reports which Gateway request failed, and the
  Central Server answers whoever is waiting with `gateway_unavailable`.
- **An answer to nothing is refused, not invented.** An `external_response`
  that matches no open call gives `nat_flow_missing`. The Central Server does
  not guess which Computer it might have been for.
- **A spent sequence is never reissued.** Traffic Events lost to a disconnect
  mid-batch are not re-queued under the same numbers; the far end records the
  hole. This is the same rule Milestone 6 settled from the other side.
- **The Central Server owns its own loop.** It is the one role with two things
  to wait on, so `Central:run` replaced the generic runtime loop rather than
  the Gateway being driven from somewhere it could be forgotten.

## Gate evidence

`make fmt-check` and `make test`: **253 Lua tests, 0 failures**, the fixture
catalog valid and regenerating to no diff, and the Go suite under `-race` at two
seeds.

Three existing tests changed, each because this milestone changed what is true:

| Test | Was | Is |
|---|---|---|
| `core_scenarios_test.lua` scenario 10 | `external_response` inward is `forbidden_operation` | it is carried inward; one matching no call is `nat_flow_missing` |
| `role_internet_test.lua` | no Gateway adapter was ever wired | the transport exists and has never reached anything |
| `protocol_encapsulation_test.lua` | the documented surface | plus `gateway` and `registration` |

## What is not met, and why

**No in-world run has been performed.** Every result above comes from Lua on a
real interpreter and Go under `-race`. The two ends have still never run as one
pair of processes: what proves the path here is a stand-in for `craftnetd` on
the same seam the real adapter uses, not `craftnetd` itself.

**Subordinate roles do not relay Traffic Events upstream.** A Customer Router
and an ISP record their own, and the Central Server reports its own, but there
is no in-world `traffic_batch` from a child to its parent. `traffic_batch` is in
the operational transport for it, and nothing sends one. Scenario 9 will
therefore show the Central Server's view of traffic and not a router's. This is
a gap no ticket settles and the acceptance report does not name; it wants
deciding, not improvising, exactly as this milestone's own question did.

**`device.rotate` is still not registered.** Re-registering already covers
recovering a lost credential, as Milestone 6 decided.

The repository stays at `0.1.0-dev`. Scenario 8 is no longer blocked — but a
scenario is passed by running it, not by building what it needed.
