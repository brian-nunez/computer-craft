Type: grilling
Status: resolved
Blocked by:

## Question

What must a player be able to build, observe, configure, break, and recover in the CraftNet v1 reference scenario for the project to count as successful, and which qualities are essential versus optional?

## Answer

The player is the Operator: they install CraftNet through `ccpm`, place and interactively configure one Central Server, one ISP, and the Home and Farm Customer Routers. Computers join a Customer Network using its LAN Password and otherwise receive their configuration automatically.

CraftNet v1 succeeds when the reference scenario can demonstrate all of the following:

1. Start one Central Server and register one ISP.
2. Connect Home and Farm Customer Routers using overlapping RFC 1918 address ranges.
3. Attach multiple Computers through LAN Password authentication and automatic network configuration.
4. Resolve names and exchange messages within and between Customer Networks.
5. Demonstrate that cross-network traffic traverses the Customer Routers and Central Server.
6. Call an allowlisted External Application operation through the Central Server's WebSocket.
7. Display the complete topology and all device traffic on the External Application dashboard.
8. Disable Farm from the dashboard, visibly block its upstream traffic, re-enable it, and recover without reinstalling any component.

Every Computer must expose its address, router, DNS service, and connection state. Customer Routers must expose attached Computers, address assignments, and NAT flows. The ISP must expose registered Customer Routers and Provider Addresses. The Central Server must expose ISPs, routes, WebSocket status, and rejected traffic. Plain terminal tables are acceptable in v1; polished graphics are optional.

Interactive setup programs are required for infrastructure, while advanced settings may remain directly editable. Routine restarts or temporary disconnections of a Computer, Customer Router, ISP node, or Central Server must preserve identity and configuration, clearly report degraded state, and recover automatically. Corrupted state, lost credentials, competing Central Servers, and high availability are outside the v1 reliability boundary.
