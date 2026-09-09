Type: grilling
Status: resolved
Blocked by: 05, 07, 08

## Question

How does the Central Server's single real WebSocket connection carry allowlisted External Application requests and replies while proving the originating ISP, Customer Network, Customer Router, and Computer and preserving the simulated route?

## Answer

Each Central Server opens one outbound `wss://` connection to the configured External Application. It presents its World identity and Gateway Credential during the handshake. The External Application validates both, negotiates a protocol version, and creates one Gateway Session for that World. Computers, Customer Routers, and ISPs never open External Application connections.

Every hop derives and appends authenticated ancestry rather than trusting claims from below it. By the time a request reaches the Central Server, it has verified World, ISP, Customer Network, Customer Router, Computer, Request ID, and NAT Flow context. The Central Server rejects disabled networks and invalid routes before forwarding.

The WebSocket carries a small set of semantic message families whose exact schemas will be fixed in the wire-schema ticket:

- Gateway handshake, heartbeat, and acknowledgement
- External Operation request, response, and error
- Topology snapshot and topology change
- Traffic Event batch
- Administrative command and command result

An External Operation identifies a named operation and structured payload rather than an arbitrary URL, HTTP method, or headers. The External Application owns the allowlist that maps names to handlers. The gateway request includes the verified ancestry, Request ID, opaque two-minute Access Token, operation name, and payload. The External Application validates the Gateway Credential, validates that the Access Token's device and World claims match the ancestry, authorizes the operation, and returns a response correlated by Request ID. The reply follows the same simulated route and NAT Flow back to the originating Computer.

Device registration and Access Token requests are themselves dedicated External Operations carried through the same gateway path. They use the Device Credential instead of an Access Token where appropriate and still require a valid Gateway Session.

After connecting or reconnecting, the Central Server sends a full topology snapshot followed by changes and Traffic Event batches. Administrative commands carry unique command IDs; the Central Server acknowledges them, persists accepted Network Status changes, and returns the applied result so retries are idempotent. The dashboard marks its view stale whenever the Gateway Session is absent.

If the WebSocket disconnects, the Central Server reconnects with bounded exponential backoff. Pending External Operations fail with `gateway_unavailable` or `request_timeout` and are never replayed automatically. The Central Server retains only its rolling Traffic Event buffer, sends what remains after reconnecting, and then publishes a new topology snapshot. Internal CraftNet traffic continues normally.
