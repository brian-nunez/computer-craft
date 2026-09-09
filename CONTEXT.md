# CraftNet

CraftNet is an in-world networking game built on CC:Tweaked. One world-level Central Server connects independently operated ISPs, their customer networks, and a controlled bridge to an external application.

## Language

**CraftNet**:
The complete virtual internetwork within one Minecraft world, including the Central Server, ISPs, Customer Networks, and the bridge to the External Application.
_Avoid_: The network

**Customer Network**:
An independently administered local network, such as Home or Farm, whose Computers use RFC 1918 addresses and reach its ISP through one Customer Router.
_Avoid_: Small network, LAN

**Customer Router**:
The boundary node for a Customer Network. It supplies local addressing information and represents its Computers to one ISP through simplified NAT.
_Avoid_: Home server, network server

**ISP**:
An independently operated provider that connects any number of Customer Routers to CraftNet through the Central Server. A world may contain any number of ISPs; the initial test topology contains one.
_Avoid_: Central Server, public internet

**Provider Address**:
An address from `100.64.0.0/10` assigned within an ISP's transit space, including addresses used by Customer Routers.
_Avoid_: Public IP, external IP

**Provider Allocation**:
A non-overlapping range of RFC 6598 addresses delegated by the Central Server to one ISP for its own infrastructure and Customer Routers.
_Avoid_: Customer address pool, subnet route

**Address Binding**:
The durable association between one Computer and its RFC 1918 address within one Customer Network.
_Avoid_: DHCP lease, Provider Address

**CraftNet Name**:
A case-insensitive hierarchical name that identifies a Computer through its hostname, Customer Network, and ISP, with `.craft` as the explicit world-local suffix.
_Avoid_: Internet domain, Computer ID

**Logical Interface**:
A CraftNet boundary that binds an infrastructure role to a modem and channel for either upstream, downstream, or local communication.
_Avoid_: Modem, network card

**Discovery Channel**:
A well-known modem channel used only to find and begin enrollment with an upstream CraftNet role.
_Avoid_: Operational Channel, secure channel

**Operational Channel**:
A modem channel assigned after enrollment for routine communication between authenticated CraftNet roles.
_Avoid_: Discovery Channel, private channel

**Authenticated Session**:
A temporary relationship between two enrolled CraftNet roles in which signed messages share a fresh session identity and replay counter sequence.
_Avoid_: Operational Channel, Access Token

**Central Server**:
The single trusted world-level node that coordinates CraftNet, connects its ISPs, and bridges approved traffic to the External Application. It is infrastructure shared by all ISPs and is not itself an ISP.
_Avoid_: ISP, provider, internet

**Computer**:
An end device attached beneath a Customer Router. A Customer Network may contain any number of Computers, including stationary computers and turtles.
_Avoid_: Router, client node

**Network Status**:
The Central Server's authoritative enabled or disabled state for a Customer Network, independent of whether that network is currently reachable.
_Avoid_: Online status, dashboard state

**Traffic Event**:
A metadata record describing an attempted CraftNet communication without including its payload body.
_Avoid_: Packet capture, message

**NAT Flow**:
A temporary association created by a Customer Router between one local request and its routable Provider Address identity so that replies return to the correct Computer.
_Avoid_: Address Binding, connection

**Exposed Service**:
A named operation on a Computer that its Customer Router explicitly permits other Customer Networks to initiate.
_Avoid_: Open port, application

**Route Registration**:
The Central Server's durable association of one Customer Network identity with its owning ISP and Customer Router Provider Address.
_Avoid_: Route advertisement, DNS record

**Operator**:
The player who builds and administers the Central Server, ISPs, Customer Routers, and Customer Networks.
_Avoid_: User, administrator

**LAN Password**:
A shared enrollment secret that permits a Computer to join the local Customer Network served by a Customer Router.
_Avoid_: Router Enrollment Token, Device Credential

**LAN Credential**:
A durable credential issued by a Customer Router to one joined Computer for authenticating routine local network traffic.
_Avoid_: LAN Password, Device Credential

**External Application**:
The trusted service running outside Minecraft that exposes the allowlisted API used by CraftNet.
_Avoid_: Internet, web server

**Gateway Session**:
The authenticated WebSocket relationship between one World's Central Server and the External Application.
_Avoid_: Authenticated Session, API connection

**External Operation**:
A named, allowlisted action that a Computer requests from the External Application through its complete CraftNet ancestry.
_Avoid_: URL, HTTP request

**World Key**:
A high-entropy root secret generated by the External Application when provisioning a Central Server and used to derive purpose-specific in-world enrollment and relationship secrets.
_Avoid_: Gateway Credential, ISP Credential

**ISP Enrollment Token**:
A credential issued by the Central Server that permits an ISP to register upstream.
_Avoid_: ISP Credential, Router Enrollment Token

**ISP Credential**:
A durable credential issued after ISP enrollment for authenticating routine communication between one ISP and the Central Server.
_Avoid_: ISP Enrollment Token, Gateway Credential

**Router Enrollment Token**:
A credential issued by an ISP that permits a Customer Router to register upstream.
_Avoid_: Router Credential, ISP Enrollment Token

**Router Credential**:
A durable credential issued after router enrollment for authenticating routine communication between one Customer Router and its ISP.
_Avoid_: Router Enrollment Token, LAN Credential

**Device Credential**:
A durable credential issued by the External Application after a Customer Router vouches for a device.
_Avoid_: Device token

**Access Token**:
A short-lived JWT authorizing a device to call approved External Application operations through CraftNet.
_Avoid_: API key, device credential

**Gateway Credential**:
A credential that authenticates the Central Server to the External Application.
_Avoid_: ISP Enrollment Token, Access Token
