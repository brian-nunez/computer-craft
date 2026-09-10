-- Authenticated operational frames.
--
-- A receiver validates types, size, relationship, session, strictly increasing
-- counter, body hash, and MAC -- in that order -- before anything is dispatched.
-- Callers above this file never see a MAC, a counter, or a canonical form.

local internal = ...
local cj1 = internal("cj1")
local keys = internal("keys")
local schema = internal("schema")
local limits = internal("limits")
local errors = internal("errors")

local frame = {}

local FIRST_COUNTER = 1
frame.FIRST_COUNTER = FIRST_COUNTER

local envelopeShape = {
  required = {
    v = "integer",
    kind = "operation_name",
    relationship_id = "id",
    session_id = "id",
    counter = "positive",
    body = "object",
    body_hash = "digest",
    mac = "digest",
  },
  optional = { request_id = "id" },
}

frame.envelopeShape = envelopeShape

--------------------------------------------------------------------------
-- Sessions
--------------------------------------------------------------------------

local Session = {}
Session.__index = Session

-- newSession creates the live counter state for one Authenticated Session.
-- Reconnection always creates a new session rather than resuming old traffic.
function frame.newSession(options)
  assert(schema.scalars.id(options.relationship_id), "relationship_id must be a CraftNet ID")
  assert(schema.scalars.id(options.session_id), "session_id must be a CraftNet ID")
  assert(type(options.session_key) == "string" and #options.session_key > 0,
    "session_key must be raw bytes derived from the relationship credential")
  return setmetatable({
    relationshipId = options.relationship_id,
    sessionId = options.session_id,
    sessionKey = options.session_key,
    transport = options.transport or "operational",
    maximumBytes = options.maximum_bytes or limits.MODEM_FRAME_BYTES,
    outboundCounter = FIRST_COUNTER,
    highestInboundCounter = 0,
  }, Session)
end

function Session:nextCounter()
  return self.outboundCounter
end

-- seal produces the wire text for one outbound message and only then commits
-- the counter, so a failed encode never burns a counter value.
function Session:seal(kind, body, requestId)
  if not schema.allows(self.transport, kind) then
    return nil, "invalid_message", "kind '" .. tostring(kind) .. "' is not carried by this transport"
  end
  local valid, message, code = schema.validateBody(kind, body)
  if not valid then return nil, code, message end
  if requestId ~= nil and not schema.scalars.id(requestId) then
    return nil, "invalid_message", "request_id must be a CraftNet ID when present"
  end

  local bodyHash, hashCode, hashMessage = keys.bodyHash(body)
  if not bodyHash then return nil, hashCode, hashMessage end

  local counter = self.outboundCounter
  local mac, macCode, macMessage = keys.mac(
    self.sessionKey, kind, self.relationshipId, self.sessionId, requestId, counter, bodyHash)
  if not mac then return nil, macCode, macMessage end

  local envelope = cj1.object({
    v = schema.VERSION,
    kind = kind,
    relationship_id = self.relationshipId,
    session_id = self.sessionId,
    counter = counter,
    body = body,
    body_hash = bodyHash,
    mac = mac,
  })
  if requestId ~= nil then rawset(envelope, "request_id", requestId) end

  local text, encodeCode, encodeMessage = cj1.encode(envelope)
  if not text then return nil, encodeCode, encodeMessage end
  if #text > self.maximumBytes then
    return nil, "message_too_large", "frame exceeds " .. self.maximumBytes .. " bytes"
  end

  self.outboundCounter = counter + 1
  return text, counter
end

-- open validates and authenticates one inbound frame. The counter is committed
-- only after the MAC verifies, so a forged frame cannot advance the window.
function Session:open(text)
  if type(text) ~= "string" then
    return nil, "invalid_message", "frame must be a string"
  end
  -- A receiver discards oversized frames before JSON decoding.
  if #text > self.maximumBytes then
    return nil, "message_too_large", "frame exceeds " .. self.maximumBytes .. " bytes"
  end

  local envelope, decodeCode, decodeMessage = cj1.decode(text)
  if not envelope then return nil, decodeCode, decodeMessage end

  local ok, message, code = schema.validateShape(envelopeShape, envelope, "frame")
  if not ok then return nil, code or "invalid_message", message end

  if rawget(envelope, "v") ~= schema.VERSION then
    return nil, "unsupported_version", "frame declares version " .. tostring(rawget(envelope, "v"))
  end

  local kind = rawget(envelope, "kind")
  if not schema.allows(self.transport, kind) then
    return nil, "invalid_message", "kind '" .. kind .. "' is not carried by this transport"
  end

  if rawget(envelope, "relationship_id") ~= self.relationshipId then
    return nil, "authentication_failed", "frame names another relationship"
  end
  if rawget(envelope, "session_id") ~= self.sessionId then
    return nil, "authentication_failed", "frame names another session"
  end

  local counter = rawget(envelope, "counter")
  if counter <= self.highestInboundCounter then
    return nil, "replay_rejected", "counter " .. counter .. " is not greater than "
      .. self.highestInboundCounter
  end

  local body = rawget(envelope, "body")
  local bodyHash, hashCode, hashMessage = keys.bodyHash(body)
  if not bodyHash then return nil, hashCode, hashMessage end
  if bodyHash ~= rawget(envelope, "body_hash") then
    return nil, "invalid_message", "body_hash does not cover the body"
  end

  local requestId = rawget(envelope, "request_id")
  local expected, macCode, macMessage = keys.mac(
    self.sessionKey, kind, self.relationshipId, self.sessionId, requestId, counter, bodyHash)
  if not expected then return nil, macCode, macMessage end
  if not keys.equals(expected, rawget(envelope, "mac")) then
    return nil, "authentication_failed", "message authentication code does not verify"
  end

  -- Only an authenticated frame may be dispatched, so the body schema is
  -- checked last and a violation is reported without advancing the counter.
  local valid, bodyMessage, bodyCode = schema.validateBody(kind, body)
  if not valid then return nil, bodyCode, bodyMessage end

  self.highestInboundCounter = counter
  return {
    kind = kind,
    body = body,
    request_id = requestId,
    counter = counter,
  }
end

--------------------------------------------------------------------------
-- Unauthenticated envelopes
--------------------------------------------------------------------------

local handshakeShape = {
  required = { v = "integer", kind = "operation_name", request_id = "id", body = "object", proof = "digest" },
}

frame.handshakeShape = handshakeShape

-- sealHandshake builds the unsigned outer object used before a session key
-- exists. `proof` is an HMAC over the whole canonical outer message under the
-- one-time enrollment secret, LAN Password, or relationship credential.
function frame.sealHandshake(secret, kind, requestId, body, maximumBytes)
  if not schema.allows("handshake", kind) then
    return nil, "invalid_message", "kind '" .. tostring(kind) .. "' is not a handshake message"
  end
  local valid, message, code = schema.validateBody(kind, body)
  if not valid then return nil, code, message end
  if not schema.scalars.id(requestId) then
    return nil, "invalid_message", "request_id must be a CraftNet ID"
  end

  local proof, proofCode, proofMessage = keys.handshakeProof(secret, kind, requestId, body)
  if not proof then return nil, proofCode, proofMessage end

  local text, encodeCode, encodeMessage = cj1.encode(cj1.object({
    v = schema.VERSION,
    kind = kind,
    request_id = requestId,
    body = body,
    proof = proof,
  }))
  if not text then return nil, encodeCode, encodeMessage end

  local ceiling = maximumBytes or limits.MODEM_FRAME_BYTES
  if #text > ceiling then
    return nil, "message_too_large", "handshake exceeds " .. ceiling .. " bytes"
  end
  return text
end

-- openHandshake verifies the outer proof. Discovery-channel callers must not
-- return the detail to the peer; it exists for local logging and tests.
function frame.openHandshake(secret, text, maximumBytes)
  if type(text) ~= "string" then
    return nil, "invalid_message", "handshake must be a string"
  end
  local ceiling = maximumBytes or limits.MODEM_FRAME_BYTES
  if #text > ceiling then
    return nil, "message_too_large", "handshake exceeds " .. ceiling .. " bytes"
  end

  local envelope, decodeCode, decodeMessage = cj1.decode(text)
  if not envelope then return nil, decodeCode, decodeMessage end

  local ok, message, code = schema.validateShape(handshakeShape, envelope, "handshake")
  if not ok then return nil, code or "invalid_message", message end

  if rawget(envelope, "v") ~= schema.VERSION then
    return nil, "unsupported_version", "handshake declares version " .. tostring(rawget(envelope, "v"))
  end

  local kind = rawget(envelope, "kind")
  if not schema.allows("handshake", kind) then
    return nil, "invalid_message", "kind '" .. kind .. "' is not a handshake message"
  end

  local body = rawget(envelope, "body")
  local requestId = rawget(envelope, "request_id")
  local expected, proofCode, proofMessage = keys.handshakeProof(secret, kind, requestId, body)
  if not expected then return nil, proofCode, proofMessage end
  if not keys.equals(expected, rawget(envelope, "proof")) then
    return nil, "authentication_failed", "handshake proof does not verify"
  end

  local valid, bodyMessage, bodyCode = schema.validateBody(kind, body)
  if not valid then return nil, bodyCode, bodyMessage end

  return { kind = kind, body = body, request_id = requestId }
end

-- Discovery is unauthenticated by design: it only finds a parent and begins
-- enrollment, and it carries no secret and no state.
local discoveryShape = {
  required = { v = "integer", kind = "operation_name", body = "object" },
}

frame.discoveryShape = discoveryShape

function frame.sealDiscovery(kind, body)
  if not schema.allows("discovery", kind) then
    return nil, "invalid_message", "kind '" .. tostring(kind) .. "' is not a discovery message"
  end
  local valid, message, code = schema.validateBody(kind, body)
  if not valid then return nil, code, message end
  return cj1.encode(cj1.object({ v = schema.VERSION, kind = kind, body = body }))
end

function frame.openDiscovery(text)
  if type(text) ~= "string" then
    return nil, "invalid_message", "discovery message must be a string"
  end
  if #text > limits.MODEM_FRAME_BYTES then
    return nil, "message_too_large", "discovery message exceeds " .. limits.MODEM_FRAME_BYTES .. " bytes"
  end
  local envelope, decodeCode, decodeMessage = cj1.decode(text)
  if not envelope then return nil, decodeCode, decodeMessage end
  local ok, message, code = schema.validateShape(discoveryShape, envelope, "discovery")
  if not ok then return nil, code or "invalid_message", message end
  if rawget(envelope, "v") ~= schema.VERSION then
    return nil, "unsupported_version", "discovery declares version " .. tostring(rawget(envelope, "v"))
  end
  local kind = rawget(envelope, "kind")
  if not schema.allows("discovery", kind) then
    return nil, "invalid_message", "kind '" .. kind .. "' is not a discovery message"
  end
  local body = rawget(envelope, "body")
  local valid, bodyMessage, bodyCode = schema.validateBody(kind, body)
  if not valid then return nil, bodyCode, bodyMessage end
  return { kind = kind, body = body }
end

frame.errors = errors

return frame
