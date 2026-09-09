# Build CraftNet on raw modem channels

CraftNet carries its control and data protocols over raw modem channels instead of Rednet. Owning the transport enables explicit discovery and operational channels, Logical Interfaces, and hierarchy enforcement needed by the networking simulation, at the cost of implementing message addressing, correlation, validation, and forwarding within CraftNet.
