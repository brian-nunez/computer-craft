Type: grilling
Status: resolved
Blocked by: 02, 03

## Question

How are ISPs, Customer Routers, and Computers enrolled, authenticated, rotated, revoked, and rejoined through the delegated trust chain, and what is the lifecycle for LAN Passwords, ISP Enrollment Tokens, Router Enrollment Tokens, Device Credentials, two-minute Access Tokens, and Gateway Credentials without treating secrets as identity?

## Answer

Every upstream relationship separates one-time enrollment from ongoing authentication:

- An ISP Enrollment Token is exchanged for an ISP Credential.
- A Router Enrollment Token is exchanged for a Router Credential.
- A LAN Password admits a Computer once, after which it receives a unique LAN Credential.

Enrollment tokens become invalid after successful use. Durable relationship credentials survive routine restarts and authenticate later connections. Secrets prove an already assigned identity; they are never used as the identity itself.

Authority is delegated. The Central Server creates, lists, and revokes credentials for ISPs. Each ISP does the same for its Customer Routers. Each Customer Router changes its LAN Password and lists or revokes joined Computers. The External Application creates and revokes Gateway Credentials and Device Credentials and issues Access Tokens. Revocation immediately rejects new authenticated traffic but does not delete the child's identity or configuration; an Operator may re-enroll the same logical child with a new one-time token.

After LAN Password challenge-response succeeds, the Customer Router establishes a unique LAN Credential for that Computer. Changing the shared password affects future joins only. Existing Computers remain enrolled until individually revoked.

External registration follows the complete trust chain: the Customer Router vouches for LAN membership, the ISP and Central Server preserve the authenticated ancestry, and the External Application issues a durable Device Credential. The Computer uses this credential to request an Access Token valid for two minutes and may reuse it until expiration. An external request must present both the Computer's Access Token and the Central Server's separate Gateway Credential.

CC:Tweaked 1.117.1 has no built-in hashing, HMAC, secure-random, or JWT API, and raw `modem_message` events expose no trustworthy sender identity. CraftNet therefore bundles a reviewed pure-Lua HMAC-SHA-256 implementation. Each operational message authenticates a canonical representation of the protocol version, relationship ID, session ID, request ID, message counter, message type, and body hash. A successful challenge-response handshake creates a fresh Authenticated Session; receivers reject repeated or out-of-order counters within that session. Reconnection creates a new session rather than resuming old traffic.

The External Application generates the Central Server's high-entropy World Key and Gateway Credential during initial provisioning. The Central Server derives purpose-separated ISP enrollment and relationship secrets from the World Key; an ISP derives Router secrets from its own credential; and a Customer Router derives unique LAN Credentials after password authentication. Initial Central Server provisioning therefore requires the External Application, but later in-world enrollment does not.

LAN Passwords provide gameplay-level admission rather than strong hostile-radio security. The password is never transmitted directly: the router uses challenge-response and rate-limits failures. Nevertheless, a captured exchange may enable an offline dictionary attack against a weak password. Encryption, traffic-analysis resistance, radio-jamming protection, and defense against an attacker reading a Computer's files are outside v1.

The External Application creates and validates JWT Access Tokens. CraftOS transports them as opaque bearer strings and uses the returned expiration time without decoding or verifying the JWT. A captured Access Token is insufficient on its own because the External Application also requires a valid Gateway Credential and authenticated CraftNet ancestry.

Research sources: [CC:Tweaked 1.117.1 API](https://tweaked.cc/mc-1.21.y/), [`modem_message`](https://tweaked.cc/mc-1.21.y/event/modem_message.html), [modem peripheral](https://tweaked.cc/mc-1.21.y/peripheral/modem.html), and [Rednet security warning](https://tweaked.cc/mc-1.21.y/module/rednet.html#network-security).
