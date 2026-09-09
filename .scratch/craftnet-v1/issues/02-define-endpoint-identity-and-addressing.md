Type: grilling
Status: resolved
Blocked by:

## Question

What uniquely identifies Worlds, ISPs, Customer Networks, Customer Routers, Computers, interfaces, and conversations when Customer Networks may reuse the same RFC 1918 addresses, and which identifiers are visible to players?

## Answer

CraftNet uses a delegated identity and address hierarchy. Each entity is responsible for registering and addressing the entities immediately beneath it:

- The Central Server creates the World identity, registers ISPs, assigns each ISP an immutable ID and a non-overlapping RFC 6598 allocation, and authenticates to the External Application with its Gateway Credential.
- An ISP registers Customer Routers, assigns each an immutable Router identity and a unique Provider Address from the ISP's allocation, and requires a Router Enrollment Token for upstream registration.
- A Customer Router recognizes a Computer by its ComputerCraft computer ID, admits it with the Customer Network's LAN Password, assigns its local RFC 1918 address, and records the binding.
- An ISP authenticates upstream using an ISP Enrollment Token issued by the Central Server.

Player-chosen names are editable labels rather than primary identities. A Customer Network's RFC 1918 addresses are unique only within that Customer Network, so Home and Farm may both assign `192.168.1.20`. The complete identity of an end-device address is the Customer Network identity plus its local RFC 1918 address; infrastructure retains that scope while forwarding.

The Operator configures infrastructure through role-specific commands:

```text
craftnet setup central
craftnet setup isp
craftnet setup router
craftnet join
```

Each wizard collects only the configuration owned by that role and requires the credential issued by its immediate upstream authority. In-game screens show only identity, connection state, and serious errors. Provider Addresses, local addresses, internal IDs, topology, and traffic details are primarily visible through the External Application dashboard.

Every request receives a unique Request ID for logging and reply correlation. The routing and NAT ticket will decide any additional conversation or flow identity.
