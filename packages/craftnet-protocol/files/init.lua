-- craftnet-protocol: the CraftNet v1 wire.
--
-- This package is deliberately deep. Callers open an enrolled link and exchange
-- semantic messages; CJ1 canonicalization, SHA-256, HMAC, key derivation,
-- schema validation, the session handshake, counters, replay rejection,
-- framing, correlation, size limits, and timeouts all stay inside it. No caller
-- outside this package calculates a MAC or a canonical form.

local moduleDirectory = (function()
  local source = debug.getinfo(1, "S").source
  local path = string.match(source, "^@(.*)$") or source
  return string.match(path, "^(.*)[/\\][^/\\]*$") or "."
end)()

local loaded = {}
local loading = {}

-- internal resolves a sibling file by path rather than through `require`, so the
-- package works identically from a ccpm lock path on a CC:Tweaked computer and
-- from a checkout during tests.
local function internal(name)
  local cached = loaded[name]
  if cached ~= nil then return cached end
  assert(not loading[name], "circular protocol module dependency at '" .. name .. "'")
  loading[name] = true
  local chunk, loadError = loadfile(moduleDirectory .. "/" .. name .. ".lua")
  assert(chunk, "craftnet-protocol cannot load module '" .. name .. "': " .. tostring(loadError))
  local module = chunk(internal)
  loading[name] = nil
  loaded[name] = module
  return module
end

local cj1 = internal("cj1")
local errors = internal("errors")
local frame = internal("frame")
local handshake = internal("handshake")
local keys = internal("keys")
local limits = internal("limits")
local link = internal("link")
local schema = internal("schema")
local tokens = internal("tokens")

local protocol = {
  name = "craftnet-protocol",
  version = "0.1.0",
  wireVersion = schema.VERSION,
}

--------------------------------------------------------------------------
-- Value construction
--------------------------------------------------------------------------

-- An empty Lua table is ambiguous on the wire, so an empty array must be built
-- explicitly. Anything non-empty is classified the way it would be signed.
protocol.object = cj1.object
protocol.array = cj1.array
protocol.null = cj1.null

--------------------------------------------------------------------------
-- Links
--------------------------------------------------------------------------

-- open wraps an established Authenticated Session in the link interface.
protocol.open = link.open

-- Discovery and enrollment are constructors on the package because they produce
-- an enrolled link rather than a second transport abstraction.
protocol.childEnrollment = handshake.childEnrollment
protocol.parentEnrollment = handshake.parentEnrollment
protocol.childSession = handshake.childSession
protocol.parentSession = handshake.parentSession

-- Before a session exists there are still two framings a role package has to
-- put on the wire itself: the unauthenticated discovery that finds a parent,
-- and the outer proof that carries an enrollment or a reconnect. They are
-- public for that reason and no other -- neither one calculates a MAC, a
-- counter, or a canonical form on the caller's behalf.
protocol.discovery = {
  seal = frame.sealDiscovery,
  open = frame.openDiscovery,
}

protocol.handshake = {
  seal = frame.sealHandshake,
  open = frame.openHandshake,
}

-- The Gateway is the one CraftNet link that is not a modem relationship and
-- carries no session MAC: it is a WebSocket, authenticated once in its
-- Authorization header and trusted afterwards through WSS and the session it
-- opened. Its envelope still belongs to the protocol, so a Central Server's
-- transport adapter moves bytes and nothing else.
protocol.gateway = internal("gateway")

-- Registering a device with the External Application is the one exchange a
-- Computer takes part in that is not a CraftNet handshake, and it still needs a
-- value that is different every time. CraftOS never uses math.random as a
-- security source, so it is derived exactly as a handshake nonce is: from the
-- durable LAN Credential and a counter the Computer commits before it sends.
--
-- The derivation is named for what it is for rather than exposed as a key
-- helper, so nothing outside this package is ever handed one.
protocol.registration = {
  nonce = function(lanCredential, generation)
    return keys.nonce(lanCredential, "computer", generation)
  end,
}

-- One-time enrollment tokens. A parent issues one, an Operator carries it to a
-- child, and the child proves the exchange under it exactly as a Computer
-- proves a LAN join under a LAN Password.
protocol.tokens = tokens

--------------------------------------------------------------------------
-- Errors and limits
--------------------------------------------------------------------------

protocol.errors = errors
protocol.limits = limits

--------------------------------------------------------------------------
-- Wire vocabulary
--------------------------------------------------------------------------

-- This package owns what a CraftNet identifier, name, and address are. The
-- predicates are public so that craftnet-core can check a value against the
-- wire's own rules instead of carrying a second copy of them that could drift.
-- They answer questions about values; they never validate a whole message.
protocol.validate = {
  identifier = schema.scalars.id,
  normalizedName = schema.scalars.normalized_name,
  displayName = schema.scalars.display_name,
  operationName = schema.scalars.operation_name,
  nonce = schema.scalars.nonce,
  channel = schema.scalars.channel,
  revision = schema.scalars.revision,
  customerAddress = schema.scalars.customer_address,
  providerAddress = schema.scalars.provider_address,
  role = schema.scalars.role,
  connectivityState = schema.scalars.connectivity_state,
  networkStatus = schema.scalars.network_status,
  -- Which credential an External Operation may present. This one reads several
  -- fields rather than one value, which makes it the exception here; it is
  -- public for the same reason the rest are, so that a Computer refusing its
  -- own mistake and the External Application refusing it apply one rule.
  credentialUse = schema.validateCredentialUse,
}

--------------------------------------------------------------------------
-- Conformance surface
--------------------------------------------------------------------------

-- The cross-language fixture catalog under spec/protocol/v1 is the executable
-- source of truth. These entry points exist so the catalog can be replayed in
-- Lua exactly as it is in Go; ordinary callers do not need them.
protocol.conformance = {
  cj1 = cj1,
  keys = keys,
  frame = frame,
  schema = schema,
  sha256 = internal("sha256"),
  hmac = internal("hmac"),
}

protocol.internal = internal

return protocol
