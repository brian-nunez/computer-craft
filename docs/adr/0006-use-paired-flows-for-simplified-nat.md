# Use paired flows for simplified NAT

CraftNet models NAT with ephemeral flow identifiers under each Customer Router's Provider Address rather than TCP/UDP ports. Paired source and destination flow records allow replies to reach the correct Computer behind overlapping RFC 1918 Customer Networks, while named Exposed Services control new inbound requests and missing flow state fails closed.
