Type: grilling
Status: resolved
Blocked by: 02, 03, 04

## Question

How do Computers discover a Customer Router, receive and retain RFC 1918 configuration, resolve local and remote names, handle duplicate names and exhausted pools, and recover when their router is unavailable?

## Answer

The Customer Router setup wizard collects the Customer Network name, the router's local RFC 1918 address, the first and last assignable RFC 1918 addresses, LAN type, and LAN Password. It validates that the addresses belong to RFC 1918 space, the pool excludes the router address, and the range is internally consistent. CraftNet v1 does not request or use a subnet mask: every Computer sends CraftNet traffic through its Customer Router.

Computer configuration uses a simplified DHCP-style exchange:

```text
Computer → DISCOVER on the LAN Discovery Channel
Router   → OFFER with Customer Network name and router identity
Computer → selects the offer and proves its LAN Password
Router   → ACK with configuration and a unique LAN Credential
```

The acknowledged configuration contains the Customer Network identity, local RFC 1918 address, router address and identity, DNS address, LAN Operational Channel, and durable LAN Credential. The Customer Router is both the default gateway and DNS service.

Address assignment has no lease duration. The Customer Router creates an Address Binding between the Computer and the lowest available address in its configured pool. The binding survives restarts, and a returning Computer receives the same address until the Operator explicitly releases it. The router never evicts another Computer to satisfy a new request.

CraftNet Names form a delegated, case-insensitive hierarchy:

```text
miner-1                         local Customer Network
miner-1.home                    Customer Network within the current ISP
miner-1.home.acme               globally qualified within the World
miner-1.home.acme.craft         explicit CraftNet name
api.craft                       External Application
```

ISP names are unique within a World, Customer Network names are unique within an ISP, and Computer hostnames are unique within a Customer Network. Resolution follows Computer to Customer Router to ISP to Central Server, with each role authoritative for the names immediately beneath it. Remote answers preserve Customer Network scope alongside the RFC 1918 address.

When a Computer has no chosen hostname, the router suggests `computer-<computerId>`. Duplicate names are rejected with `name_conflict`; exhausted pools return `pool_exhausted`. Both conditions require Operator action rather than automatic renaming or eviction.

If the Customer Router becomes unavailable, the Computer retains and displays its cached configuration but enters a disconnected state. It periodically searches for the same router identity and re-establishes an Authenticated Session with its LAN Credential. It never automatically joins another Customer Network, even if that network has the same name or LAN Password. Because all v1 traffic traverses the Customer Router, CraftNet communication remains unavailable until reconnection.
