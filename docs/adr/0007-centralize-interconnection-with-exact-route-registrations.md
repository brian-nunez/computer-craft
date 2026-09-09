# Centralize interconnection with exact route registrations

Every Customer Router registers its Customer Network route through its ISP, and every cross-network request traverses the Central Server even when both routers share an ISP. Exact Customer Network route maps and centrally delegated RFC 6598 allocations preserve overlapping customer addresses and strong ownership boundaries without implementing prefix routing or a dynamic inter-ISP protocol, at the cost of making the Central Server the single interconnection point.
