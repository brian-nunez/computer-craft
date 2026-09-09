## Destination

An implementation-ready specification and ordered delivery plan for CraftNet v1: one Central Server per world, any number of ISPs and Customer Routers, overlapping RFC 1918 customer addressing behind simplified NAT, RFC 6598 provider addressing, and controlled access to one External Application. The reference deployment proves the design with one ISP, Home and Farm routers, and multiple Computers.

## Notes

- Domain: CC:Tweaked networking simulation and world-building game.
- Target: Minecraft 1.21.11, Fabric, CC:Tweaked 1.117.1.
- Planning only: tickets resolve decisions; implementation begins after this map is exhausted.
- Every session should consult the `grilling` and `domain-modeling` skills, `CONTEXT.md`, and `docs/adr/`.
- Preserve the existing `ccpm` registry and package conventions unless a ticket explicitly decides to change them.
- The Central Server is world infrastructure, not an ISP. See `docs/adr/0001-separate-world-coordination-from-isps.md`.

## Decisions so far

<!-- Resolved ticket pointers are appended here. -->

- [Define v1 experience and success](issues/01-define-v1-experience-and-success.md): v1 is an operator-built Home/Farm demonstration with password-based LAN joins, automatic client configuration, observable end-to-end traffic, controlled external access, administrative isolation, and routine restart recovery.
- [Define endpoint identity and addressing](issues/02-define-endpoint-identity-and-addressing.md): identity, addressing, and upstream authentication are delegated Central Server to ISP to Customer Router to Computer; customer addresses are network-scoped, provider allocations do not overlap, and detailed identities live in the external dashboard.
- [Assign authority and state ownership](issues/03-assign-authority-and-state-ownership.md): in-world authorities own durable network state and continue operating without the External Application; the application owns external identity and historical projections, while live flows and caches are rebuilt after restarts.
- [Choose physical transport and segmentation](issues/04-choose-physical-transport-and-segmentation.md): CraftNet uses raw modem channels, Ender-modem provider links, one wired or wireless LAN per Customer Router, public discovery plus assigned operational channels, and authenticated parent-child boundaries that reject bypass traffic.
- [Design enrollment and authentication](issues/05-design-enrollment-and-authentication.md): one-time enrollment creates revocable per-relationship credentials; raw-modem sessions use pure-Lua HMAC-SHA-256 and replay counters rooted in an externally generated World Key, while opaque two-minute JWTs and a Gateway Credential protect external operations.
- [Define address configuration and DNS](issues/06-define-address-configuration-and-dns.md): routers provide permanent RFC 1918 Address Bindings through a DHCP-style join, act as gateway and DNS, resolve hierarchical `.craft` names through the ownership chain, and reconnect Computers only to their original router identity.
- [Prototype routing and NAT contract](issues/07-prototype-routing-and-nat-contract.md): local requests stay behind the Customer Router, while remote requests use scoped destinations, explicit Exposed Services, and paired ephemeral NAT Flows routed through ISP and Central Server maps with distinct failure outcomes.
- [Define ISP registration and interconnection](issues/08-define-isp-registration-and-interconnection.md): the Central Server delegates non-overlapping RFC 6598 allocations to authenticated ISPs, accepts exact Customer Network route registrations through them, and remains the sole path for same-ISP and cross-ISP traffic.
- [Define external gateway contract](issues/09-define-external-gateway-contract.md): one authenticated outbound WebSocket per World carries named External Operations, verified ancestry, topology, traffic telemetry, and idempotent administrative commands; disconnects fail requests without disrupting internal networking.
- [Choose external runtime and storage](issues/10-choose-external-runtime-and-storage.md): a single Node.js 24 TypeScript/Fastify application serves WebSocket, API, authentication, dashboard, and static assets using file-backed SQLite through `better-sqlite3`, with no distributed infrastructure in v1.

## Not yet specified

- Detailed dashboard visual design, pending the control-surface and telemetry decisions.
- Capacity targets and performance limits, pending the state and transport models.

## Out of scope

- Autonomous turtle/LLM behavior; CraftNet v1 only provides the network and external-service path it could later use.
- Byte-compatible Ethernet, IPv4, TCP, UDP, BGP, ARP, packet checksums, fragmentation, and TTL behavior.
- General-purpose access to arbitrary internet origins; v1 permits one configured External Application with allowlisted operations.
- Production deployment across multiple Minecraft worlds.
- Recovery from corrupted persisted state or lost credentials.
- High availability, failover, or multiple competing Central Servers in one world.
- VLANs, trunking, bridging, and multiple Customer Network interfaces on one Customer Router.
- Payload encryption, traffic-analysis resistance, radio-jamming protection, and defense against attackers reading a Computer's files.
