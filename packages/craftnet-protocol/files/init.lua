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

--------------------------------------------------------------------------
-- Errors and limits
--------------------------------------------------------------------------

protocol.errors = errors
protocol.limits = limits

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
