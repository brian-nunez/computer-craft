# Use one semantic gateway session per World

The Central Server is the only CraftOS node that connects to the External Application, using one authenticated outbound WebSocket per World. The session carries named allowlisted operations and verified CraftNet ancestry rather than arbitrary HTTP proxy requests, ensuring external access traverses the simulated hierarchy while concentrating reconnection, telemetry, and administrative synchronization at one boundary.
