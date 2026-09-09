# Use network-scoped addresses without subnet semantics

CraftNet identifies a Computer by its Customer Network plus local RFC 1918 address and sends all Computer traffic through its Customer Router. Customer Routers configure explicit address pools without subnet masks or prefix matching, allowing Customer Networks to overlap while preserving recognizable addressing at the cost of direct local delivery and conventional IP subnet behavior.
