Type: grilling
Status: resolved
Blocked by: 02, 03, 07

## Question

How does an ISP register with the Central Server, receive and allocate RFC 6598 Provider Addresses, advertise its Customer Routers, remain isolated from other ISPs, and exchange traffic through the Central Server when more than one ISP exists?

## Answer

An ISP setup wizard discovers the Central Server, asks the Operator for an ISP name and one-time ISP Enrollment Token, and completes the authenticated enrollment handshake. The Central Server assigns an immutable ISP ID, verifies that the display name is unique within the World, establishes the ISP Credential and Operational Channel, and delegates an initial Provider Allocation from `100.64.0.0/10`.

The Central Server owns the world-wide RFC 6598 allocator. It gives each ISP a non-overlapping range, initially a `/24`, and may delegate additional `/24` ranges when requested. These ranges organize allocation only; CraftNet does not use prefix matching to route traffic. The ISP assigns the lowest available Provider Address to itself and then to each Customer Router, while the Central Server rejects any allocation or registration outside that ISP's delegated ranges.

A Customer Router uses its Router Enrollment Token to register with one ISP. The ISP assigns its Router identity, Router Credential, Operational Channel, and Provider Address, and verifies that its Customer Network name is unique within that ISP. It then sends a signed Route Registration to the Central Server that maps the immutable Customer Network identity to the ISP identity and Customer Router Provider Address. Updates and removals follow the same authenticated ownership chain.

The Central Server maintains exact route-map entries rather than a dynamic routing protocol. All cross-network traffic follows source Customer Router → source ISP → Central Server → destination ISP → destination Customer Router, even when both Customer Routers belong to the same ISP. Each hop validates its immediate authenticated relationship and ignores a child attempting to claim another ISP, Customer Router, Customer Network, Provider Address, or allocation.

ISPs have separate credentials, Operational Channels, Provider Allocations, router registries, and telemetry. They never communicate directly in v1; the Central Server is the only interconnection point. An offline ISP makes its routes unreachable but does not delete their durable registrations or reassign their addresses. Multi-ISP collections are architecturally unbounded, subject to the finite modem channels, RFC 6598 space, and runtime capacity that later tickets will quantify.
