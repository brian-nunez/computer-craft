# Authenticate modem sessions with derived keys

CraftNet authenticates canonical raw-modem messages with a bundled pure-Lua HMAC-SHA-256 implementation, fresh session challenges, and per-session replay counters. Because CC:Tweaked 1.117.1 lacks secure randomness and cryptographic APIs, the External Application provisions a high-entropy World Key and infrastructure derives purpose-specific child secrets from its authenticated parent relationship; this provides integrity and replay resistance without claiming payload confidentiality.
