-- Gateway framing.
--
-- The Central Server opens one outbound WebSocket per World and presents its
-- Gateway Credential in the Authorization header. Frames afterwards rely on WSS
-- plus the authenticated Gateway Session rather than a second message HMAC, so
-- this layer validates structure, version, limits, and correlation only -- and
-- nothing here signs, derives, or holds a secret.
--
-- It mirrors external/internal/protocol/gateway.go field for field. The two
-- ends of one socket disagreeing about the envelope is exactly the class of
-- mistake the shared fixture catalog exists to catch.

local internal = ...
local cj1 = internal("cj1")
local schema = internal("schema")
local limits = internal("limits")

local gateway = {}

local helloShape = {
  required = {
    v = "integer", world_id = "id", central_id = "id",
    last_topology_revision = "revision", last_traffic_sequence = "non_negative",
  },
}

local welcomeShape = {
  required = {
    v = "integer", gateway_session_id = "id",
    accepted_topology_revision = "revision", accepted_traffic_sequence = "non_negative",
    server_time = "timestamp",
  },
}

local frameShape = {
  required = { v = "integer", kind = "operation_name", body = "object" },
  optional = { request_id = "id", command_id = "id" },
}

-- checkSize applies the narrower batch ceiling on top of the Gateway message
-- limit. CraftNet performs no fragmentation: an oversized batch is split by
-- whoever built it, never here.
local function checkSize(kind, text)
  if kind == "traffic_batch" and #text > limits.TRAFFIC_BATCH_BYTES then
    return false, "traffic batch exceeds " .. limits.TRAFFIC_BATCH_BYTES .. " bytes",
      "message_too_large"
  end
  if #text > limits.GATEWAY_FRAME_BYTES then
    return false, "gateway message exceeds " .. limits.GATEWAY_FRAME_BYTES .. " bytes",
      "message_too_large"
  end
  return true
end

local function decodeObject(text)
  if type(text) ~= "string" then
    return nil, "invalid_message", "a gateway message must be text"
  end
  if #text > limits.GATEWAY_FRAME_BYTES then
    return nil, "message_too_large",
      "gateway message exceeds " .. limits.GATEWAY_FRAME_BYTES .. " bytes"
  end
  local value, code, problem = cj1.decode(text)
  if not value then return nil, code or "invalid_message", problem end
  if not schema.scalars.object(value) then
    return nil, "invalid_message", "a gateway message must be an object"
  end
  return value
end

local function checkVersion(object, what)
  if rawget(object, "v") ~= schema.VERSION then
    return false, "unsupported_version",
      what .. " declares version " .. tostring(rawget(object, "v"))
  end
  return true
end

local function validated(shape, object, what)
  local ok, problem, code = schema.validateShape(shape, object, what)
  if not ok then return nil, code or "invalid_message", problem end
  return true
end

--------------------------------------------------------------------------
-- The opening exchange
--------------------------------------------------------------------------

-- encodeHello renders what the Central Server sends first. The revisions it
-- names are what the External Application answers against, so a reconnecting
-- World is told what it already has rather than resending everything.
function gateway.encodeHello(fields)
  local object = cj1.object({
    v = schema.VERSION,
    world_id = fields.world_id,
    central_id = fields.central_id,
    last_topology_revision = fields.last_topology_revision or 0,
    last_traffic_sequence = fields.last_traffic_sequence or 0,
  })
  local ok, code, problem = validated(helloShape, object, "gateway_hello")
  if not ok then return nil, code, problem end
  local text, encodeCode, encodeProblem = cj1.encode(object)
  if not text then return nil, encodeCode or "invalid_message", encodeProblem end
  return text
end

-- decodeWelcome reads the reply that opens a Gateway Session. Until it decodes,
-- there is no session: a Central Server that cannot read the welcome has not
-- connected, however healthy the socket looks.
function gateway.decodeWelcome(text)
  local object, code, problem = decodeObject(text)
  if not object then return nil, code, problem end
  local ok, shapeCode, shapeProblem = validated(welcomeShape, object, "gateway_welcome")
  if not ok then return nil, shapeCode, shapeProblem end
  local sound, versionCode, versionProblem = checkVersion(object, "gateway_welcome")
  if not sound then return nil, versionCode, versionProblem end
  return {
    gateway_session_id = rawget(object, "gateway_session_id"),
    accepted_topology_revision = rawget(object, "accepted_topology_revision"),
    accepted_traffic_sequence = rawget(object, "accepted_traffic_sequence"),
    server_time = rawget(object, "server_time"),
  }
end

--------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------

-- encodeFrame renders one Gateway message. A kind the Gateway does not carry is
-- refused here rather than sent and refused at the far end.
function gateway.encodeFrame(kind, body, correlation)
  correlation = correlation or {}
  if not schema.allows("gateway", kind) then
    return nil, "invalid_message", "'" .. tostring(kind) .. "' is not carried by the Gateway"
  end
  local ok, problem, code = schema.validateBody(kind, body)
  if not ok then return nil, code or "invalid_message", problem end

  local object = cj1.object({ v = schema.VERSION, kind = kind, body = body })
  if correlation.request_id then rawset(object, "request_id", correlation.request_id) end
  if correlation.command_id then rawset(object, "command_id", correlation.command_id) end

  local shaped, shapeCode, shapeProblem = validated(frameShape, object, "gateway_frame")
  if not shaped then return nil, shapeCode, shapeProblem end

  local text, encodeCode, encodeProblem = cj1.encode(object)
  if not text then return nil, encodeCode or "invalid_message", encodeProblem end
  local sized, sizeProblem, sizeCode = checkSize(kind, text)
  if not sized then return nil, sizeCode, sizeProblem end
  return text
end

-- decodeFrame validates one Gateway message. Everything a caller then acts on
-- has already been checked: the version, the envelope, the kind against the
-- transport, the size, and the body against its schema.
function gateway.decodeFrame(text)
  local object, code, problem = decodeObject(text)
  if not object then return nil, code, problem end
  local ok, shapeCode, shapeProblem = validated(frameShape, object, "gateway_frame")
  if not ok then return nil, shapeCode, shapeProblem end
  local sound, versionCode, versionProblem = checkVersion(object, "gateway_frame")
  if not sound then return nil, versionCode, versionProblem end

  local kind = rawget(object, "kind")
  if not schema.allows("gateway", kind) then
    return nil, "invalid_message", "'" .. tostring(kind) .. "' is not carried by the Gateway"
  end
  local sized, sizeProblem, sizeCode = checkSize(kind, text)
  if not sized then return nil, sizeCode, sizeProblem end

  local body = rawget(object, "body")
  local valid, bodyProblem, bodyCode = schema.validateBody(kind, body)
  if not valid then return nil, bodyCode or "invalid_message", bodyProblem end

  return {
    kind = kind,
    request_id = rawget(object, "request_id"),
    command_id = rawget(object, "command_id"),
    body = body,
  }
end

return gateway
