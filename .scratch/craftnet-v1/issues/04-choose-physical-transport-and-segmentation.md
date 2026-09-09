Type: grilling
Status: resolved
Blocked by:

## Question

How do wired, wireless, and Ender modems represent customer access and provider transit links, and what rules prevent a Computer from bypassing its Customer Router or impersonating infrastructure?

## Answer

CraftNet uses the raw modem API and its own channels rather than Rednet for all CraftNet control and data traffic. Rednet may coexist for unrelated programs but is not part of the CraftNet transport.

Physical roles have the following modem topology:

```text
Central Server
└── Ender modem: ISP connections

ISP
└── Ender modem: Central Server and Customer Router connections

Customer Router
├── Ender modem: ISP-facing WAN
└── one LAN modem: either wired or ordinary wireless

Computer
└── modem compatible with the Customer Router's LAN
```

An ISP may multiplex its upstream and downstream Logical Interfaces over one Ender modem using different channels. A Customer Router serves exactly one Customer Network through one wired or wireless LAN modem in v1. VLANs, trunks, bridges, and multiple LAN interfaces per router are outside v1.

CraftNet reserves well-known Discovery Channels for finding Central Servers, ISPs, and Customer Routers during interactive setup. A successful enrollment assigns an Operational Channel for that authenticated relationship. Each Customer Router also selects a LAN Operational Channel. Channel numbers reduce unrelated traffic but are public locators, not secrets or proof of identity.

Every role accepts messages only on the appropriate Logical Interface and from a relationship authenticated at the immediately lower level. A Customer Router accepts local source traffic only for joined Computers; an ISP accepts downstream traffic only for registered Customer Routers; and the Central Server accepts downstream traffic only for registered ISPs. Each parent supplies or verifies the child's authoritative identity instead of trusting source fields in the child's message.

The physical radio environment cannot stop a Computer from transmitting directly to an ISP or making its own HTTP request. CraftNet nodes ignore traffic that bypasses the hierarchy, and the External Application accepts CraftNet operations only through the authenticated Central Server WebSocket.
