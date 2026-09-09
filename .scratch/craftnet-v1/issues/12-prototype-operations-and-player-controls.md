Type: prototype
Status: resolved
Blocked by: 03, 06, 07, 09, 11

## Question

What should players see and control on in-game monitors and the external dashboard, including topology, devices, address assignments, NAT flows, traffic, failures, credentials, and the action that disables a Customer Network?

## Prototype

The validated throwaway prototype is preserved on branch `prototype/craftnet-operations-dashboard` at commit `f07d291`, path `.scratch/craftnet-v1/prototypes/operations-dashboard-prototype.html`.

## Answer

The External Application dashboard uses the topology canvas from variant B as its primary view. It shows the World, Central Server, ISPs, Customer Routers, and Computers as a navigable hierarchy, with Provider Addresses and network-scoped RFC 1918 addresses visible together. Selecting a node opens an inspector with its identity, Connectivity State, Network Status where applicable, upstream relationship, address assignments, active NAT Flow count, recent failures, and credential status. Credential values are never displayed.

Traffic and Incidents are secondary dashboard views. Traffic uses variant A's dense event table and summary counters, with filters for World role, ISP, Customer Network, Computer, operation, outcome, and time range. Incidents uses variant C's exception queue and event timeline so failures remain actionable without making routine traffic noisy. The three views share selection and filters, allowing an Operator to move from a topology node to its traffic or failures without finding it again.

The Customer Network inspector exposes an authenticated Enable or Disable action. Disabling requires confirmation, persists the Central Server's authoritative Network Status, ends that network's active sessions and NAT Flows, rejects new CraftNet operations with `network_disabled`, and records an administrative command result plus Traffic Event. Configuration, identities, Address Bindings, routes, and credentials remain intact for later re-enablement.

In-game screens intentionally remain terse. Each Central Server, ISP, or Customer Router shows only its role, name, Connectivity State, upstream name, relevant address, and latest actionable error, plus setup and recovery prompts. Computers show their hostname, local address, router, Connectivity State, and latest error. Detailed topology, history, traffic, and administrative controls belong to the external dashboard.
