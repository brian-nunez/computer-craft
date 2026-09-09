Type: prototype
Status: resolved
Blocked by: 02, 03, 04

## Question

What is the smallest concrete message and flow model that demonstrates local delivery, cross-network routing through the Central Server, overlapping RFC 1918 addresses, simplified NAT, replies, timeouts, and blocked unsolicited traffic?

## Prototype

The validated throwaway prototype is preserved on branch `prototype/craftnet-routing-nat` at commit `9196a66`, path `.scratch/craftnet-v1/prototypes/routing-nat-prototype.html`.

## Answer

CraftNet uses request/reply messages and paired, ephemeral NAT Flows rather than TCP/UDP connections or port translation.

A Computer sends every request to its Customer Router. The router derives the source Computer and Customer Network from the Authenticated Session instead of trusting source fields. A request contains the protocol version, message kind, Request ID, scoped destination, named service, payload, and the session-authentication fields settled by the authentication design.

For a local destination, the Customer Router resolves the Computer within its own Customer Network and forwards directly. No Provider Address or NAT Flow is involved, but the router still emits Traffic Events.

For a remote destination, the source Customer Router creates a NAT Flow that associates the Request ID and local Computer with a unique flow identifier under the router's Provider Address. The ISP forwards the request to the Central Server. The Central Server's route map selects the destination ISP and Customer Router from the destination Customer Network identity. The destination ISP forwards to that Customer Router.

The destination is a scoped Customer Network address plus a named service. Its Customer Router accepts a newly initiated remote request only when that service is an Exposed Service for the destination Computer. If accepted, it creates the reverse half of the NAT Flow and delivers the request locally. A reply carries the original Request ID and paired provider-flow references back through destination router, ISP, Central Server, source ISP, and source router. Those references identify the original Computer even when both Customer Networks use the same RFC 1918 address.

NAT Flows are ephemeral and expire after inactivity. A late reply or a reply with no matching flow is rejected with `nat_flow_missing`; CraftNet never guesses a destination. Newly initiated remote requests to unexposed services return `inbound_denied`. Disabled Customer Networks return `network_disabled`, missing route-map entries return `route_not_found`, and unanswered requests return `request_timeout`. Every hop emits or relays a Traffic Event with the final outcome.

The prototype validated these scenarios:

- Local delivery remains behind one Customer Router and creates no NAT Flow.
- Home and Farm Computers may both use `192.168.1.20` without ambiguity.
- A successful remote request creates paired flow state and its reply returns correctly.
- Unexposed services reject unsolicited requests.
- Expired flow state rejects late replies.
- Missing routes and administratively disabled Customer Networks produce distinct failures.
