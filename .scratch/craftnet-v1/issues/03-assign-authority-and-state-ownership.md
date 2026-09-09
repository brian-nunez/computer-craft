Type: grilling
Status: resolved
Blocked by:

## Question

Which state is authoritative at the Central Server, ISP, Customer Router, Computer, and External Application, and what may each component cache or reconstruct?

## Answer

CraftNet remains operational when the External Application or its WebSocket is unavailable. Internal address configuration, DNS, local traffic, cross-network traffic, and existing routing continue inside Minecraft. External API calls, new externally issued credentials, dashboard updates, and dashboard commands pause until connectivity returns.

State authority follows the infrastructure hierarchy:

- The Central Server owns the World identity, ISP registry, non-overlapping RFC 6598 allocations, world route directory, Customer Network Status, and External Application connection.
- Each ISP owns its identity, upstream configuration, Customer Router registry, Provider Address assignments, and issued Router Enrollment Tokens.
- Each Customer Router owns its Customer Network identity and configuration, LAN Password, RFC 1918 pool and address bindings, local DNS records, attached Computers, and forwarding policy.
- Each Computer owns its ComputerCraft ID, chosen hostname, cached network configuration, Device Credential, and application state. Its Customer Router remains authoritative for its network membership and address binding.
- The External Application owns operator login, Gateway Credential and Device Credential records, Access Token issuance, the API allowlist, dashboard history, and audit history. Its topology view is a projection rather than network authority.

An authenticated dashboard command requests a Customer Network status change, but the Central Server authoritatively persists and enforces that change.

Customer Routers emit Traffic Events for local and forwarded traffic. ISPs relay or summarize router telemetry, the Central Server produces a unified stream, and the External Application stores searchable history. Infrastructure retains only a small rolling diagnostic buffer. A Traffic Event records source, destination, operation or protocol, size, outcome, and timing, but excludes payload bodies by default.

Durable state includes identities, names, upstream configuration, address pools and bindings, DNS records, credential material, Network Status, and operator-authored policy. Active NAT flows, request correlation, presence, route and child-summary caches, the WebSocket session, and rolling diagnostic buffers are ephemeral. After restarting, a component reauthenticates upstream and reconstructs ephemeral state without changing durable identities or addresses; interrupted conversations are not resumed.
