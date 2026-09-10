-- Strict CraftNet v1 message schemas.
--
-- Every authentication and control message is validated field by field before
-- dispatch, and unknown fields are rejected. External Operation payload objects
-- are the one deliberate exception: they are application defined and may carry
-- fields this version has never seen.

local internal = ...
local cj1 = internal("cj1")
local limits = internal("limits")

local schema = {}

local VERSION = 1
schema.VERSION = VERSION

--------------------------------------------------------------------------
-- Scalar rules
--------------------------------------------------------------------------

local function isString(value)
  return type(value) == "string"
end

local function isId(value)
  return isString(value)
    and #value >= 1 and #value <= 64
    and string.match(value, "^[a-z0-9][a-z0-9_-]*$") ~= nil
end

-- Normalized names are lowercase ASCII letters, digits, and internal hyphens,
-- and they begin and end with a letter or digit.
local function isNormalizedName(value)
  if not isString(value) then return false end
  if #value < 1 or #value > 32 then return false end
  if #value == 1 then return string.match(value, "^[a-z0-9]$") ~= nil end
  return string.match(value, "^[a-z0-9][a-z0-9-]*[a-z0-9]$") ~= nil
end

local function isDisplayName(value)
  return isString(value) and #value >= 1 and #value <= 32
end

local function isOperationName(value)
  return isString(value)
    and #value >= 1 and #value <= 64
    and string.match(value, "^[a-z0-9._-]+$") ~= nil
end

local function isHex(value, bytes)
  return isString(value)
    and #value == bytes * 2
    and string.match(value, "^[0-9a-f]+$") ~= nil
end

local function isNonce(value) return isHex(value, 32) end
local function isDigest(value) return isHex(value, 32) end

local function isInteger(value)
  return cj1.isExactInteger(value)
end

local function isNonNegative(value)
  return isInteger(value) and value >= 0
end

local function isPositive(value)
  return isInteger(value) and value >= 1
end

local function isChannel(value)
  return isInteger(value) and value >= 0 and value <= 65535
end

local function isBoolean(value)
  return type(value) == "boolean"
end

-- Objects and arrays are judged by the canonical classification rather than by
-- the metatable alone, so a plain Lua table validates exactly as it would sign.
local function isObject(value)
  return cj1.classify(value) == "object"
end

local function isArray(value)
  return cj1.classify(value) == "array"
end

-- CraftOS never trusts a Computer's wall clock, so in-world durations and
-- observations are integer monotonic milliseconds.
local function isMilliseconds(value)
  return isNonNegative(value)
end

local function isTimestamp(value)
  return isString(value)
    and string.match(value, "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d") ~= nil
    and string.match(value, "Z$") ~= nil
end

local function octets(value)
  if not isString(value) then return nil end
  local a, b, c, d = string.match(value, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  local parts = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
  for index = 1, 4 do
    local part = parts[index]
    if part > 255 then return nil end
    local text = ({ a, b, c, d })[index]
    if #text > 1 and string.sub(text, 1, 1) == "0" then return nil end
  end
  return parts
end

-- Customer addresses live in RFC 1918 space; overlapping reuse across Customer
-- Networks is expected and is disambiguated by scope, never by the address.
local function isCustomerAddress(value)
  local parts = octets(value)
  if not parts then return false end
  if parts[1] == 10 then return true end
  if parts[1] == 172 and parts[2] >= 16 and parts[2] <= 31 then return true end
  if parts[1] == 192 and parts[2] == 168 then return true end
  return false
end

-- Provider Addresses live in the RFC 6598 shared space 100.64.0.0/10.
local function isProviderAddress(value)
  local parts = octets(value)
  if not parts then return false end
  return parts[1] == 100 and parts[2] >= 64 and parts[2] <= 127
end

local function enum(...)
  local allowed = {}
  for _, name in ipairs({ ... }) do allowed[name] = true end
  return function(value) return isString(value) and allowed[value] == true end
end

local isRole = enum("central", "isp", "router", "computer")
local isConnectivityState = enum("connecting", "ready", "degraded", "disconnected", "revoked")
local isNetworkStatus = enum("enabled", "disabled")
local isDirection = enum("inbound", "outbound", "local")
local isTopologyChange = enum("added", "updated", "removed")
local isEntityType = enum("isp", "customer_network", "router", "computer")
local isCommandStatus = enum("applied", "rejected")

schema.scalars = {
  id = isId,
  normalized_name = isNormalizedName,
  display_name = isDisplayName,
  operation_name = isOperationName,
  nonce = isNonce,
  digest = isDigest,
  integer = isInteger,
  non_negative = isNonNegative,
  revision = isNonNegative,
  positive = isPositive,
  channel = isChannel,
  boolean = isBoolean,
  object = isObject,
  array = isArray,
  string = isString,
  milliseconds = isMilliseconds,
  timestamp = isTimestamp,
  customer_address = isCustomerAddress,
  provider_address = isProviderAddress,
  role = isRole,
  connectivity_state = isConnectivityState,
  network_status = isNetworkStatus,
  direction = isDirection,
  topology_change = isTopologyChange,
  entity_type = isEntityType,
  command_status = isCommandStatus,
}

--------------------------------------------------------------------------
-- Composite shapes
--------------------------------------------------------------------------

local composites = {}

-- A composite is {required = {field = rule}, optional = {...}, check = fn}.
composites.source = {
  required = {
    computer_id = "id",
    customer_network_id = "id",
    local_address = "customer_address",
  },
}

composites.destination = {
  required = { customer_network_id = "id" },
  optional = { computer_id = "id", address = "customer_address" },
  check = function(value)
    local hasComputer = rawget(value, "computer_id") ~= nil
    local hasAddress = rawget(value, "address") ~= nil
    if hasComputer == hasAddress then
      return false, "destination must contain exactly one of computer_id or address"
    end
    return true
  end,
}

composites.address_binding = {
  required = {
    computer_id = "id",
    hostname = "normalized_name",
    address = "customer_address",
  },
}

composites.provider_allocation = {
  required = { first = "provider_address", last = "provider_address" },
}

composites.error_body = {
  required = { code = "string", message = "string", retryable = "boolean" },
  optional = { details = "object" },
}

composites.traffic_event = {
  required = {
    event_id = "id",
    observed_at_ms = "milliseconds",
    world_id = "id",
    direction = "direction",
    kind = "operation_name",
    outcome = "operation_name",
    bytes = "non_negative",
  },
  optional = {
    request_id = "id",
    command_id = "id",
    isp_id = "id",
    customer_network_id = "id",
    router_id = "id",
    computer_id = "id",
    operation = "operation_name",
  },
}

composites.ancestry = {
  required = {
    world_id = "id",
    isp_id = "id",
    customer_network_id = "id",
    router_id = "id",
    computer_id = "id",
    local_address = "customer_address",
  },
}

--------------------------------------------------------------------------
-- Role configuration shapes
--------------------------------------------------------------------------

local configurations = {
  computer = {
    required = {
      computer_id = "id",
      hostname = "normalized_name",
      address = "customer_address",
      customer_network_id = "id",
      router_address = "customer_address",
      dns_address = "customer_address",
    },
  },
  router = {
    required = {
      customer_network_id = "id",
      customer_network_name = "normalized_name",
      router_address = "customer_address",
      dns_address = "customer_address",
      pool_first = "customer_address",
      pool_last = "customer_address",
      lan_operational_channel = "channel",
      provider_address = "provider_address",
      isp_id = "id",
    },
    optional = { bindings = { list = "address_binding" } },
  },
  isp = {
    required = {
      isp_id = "id",
      isp_name = "normalized_name",
      provider_allocations = { list = "provider_allocation" },
      operational_channel = "channel",
    },
  },
  central = {
    required = {
      world_id = "id",
      central_id = "id",
      gateway_url = "string",
      gateway_credential_ref = "id",
      provider_allocations = { list = "provider_allocation" },
    },
  },
}

schema.configurations = configurations

-- What a parent assigns to a child is not the same as a child's complete
-- configuration. An ISP owns a Customer Router's identity, name, and Provider
-- Address; it does not own that router's LAN address, pool, or channel, and at
-- enrollment it has never even been told them. So `enroll_accept` and
-- `config_snapshot` validate against what the parent is authoritative for,
-- while `configurations` above stays the complete self-description a role
-- publishes about itself.
local assignments = {
  computer = configurations.computer,
  router = {
    required = {
      customer_network_id = "id",
      customer_network_name = "normalized_name",
      provider_address = "provider_address",
      isp_id = "id",
    },
    optional = { operational_channel = "channel" },
  },
  isp = configurations.isp,
  central = configurations.central,
}

schema.assignments = assignments

--------------------------------------------------------------------------
-- Message body schemas
--------------------------------------------------------------------------

-- validateCredentialUse fixes which credential an operation may present.
-- device.register offers the authenticated ancestry as its only attestation;
-- every other combination is rejected rather than quietly preferred. The rule
-- lives here because both legs of the external path enforce it: the in-world
-- external_call a Computer sends, and the external_request the Central Server
-- puts on the Gateway. A Computer that got it wrong is refused by its own
-- router rather than three hops later.
function schema.validateCredentialUse(value)
  local operation = rawget(value, "operation")
  local hasToken = rawget(value, "access_token") ~= nil
  local hasCredential = rawget(value, "device_credential") ~= nil
  local hasNonce = rawget(value, "registration_nonce") ~= nil
  local expected
  if operation == "device.register" then
    expected = { token = false, credential = false, nonce = true }
  elseif operation == "token.issue" or operation == "device.rotate" then
    expected = { token = false, credential = true, nonce = false }
  else
    expected = { token = true, credential = false, nonce = false }
  end
  if hasToken ~= expected.token or hasCredential ~= expected.credential or hasNonce ~= expected.nonce then
    return false, "operation '" .. tostring(operation) .. "' does not permit this credential combination"
  end
  return true
end

local bodies = {
  discover = { required = { role = "role", client_nonce = "nonce" } },
  offer = {
    required = {
      parent_id = "id",
      parent_role = "role",
      display_name = "display_name",
      discovery_channel = "channel",
      client_nonce = "nonce",
    },
  },
  enroll_open = {
    required = { role = "role", requested_name = "normalized_name", client_nonce = "nonce" },
    optional = { client_id = "id" },
  },
  enroll_challenge = {
    required = {
      parent_id = "id",
      relationship_id = "id",
      client_nonce = "nonce",
      parent_nonce = "nonce",
      parent_revision = "revision",
    },
  },
  enroll_confirm = {
    required = {
      relationship_id = "id",
      client_nonce = "nonce",
      parent_nonce = "nonce",
      child_revision = "revision",
    },
  },
  enroll_accept = {
    required = {
      child_id = "id",
      relationship_id = "id",
      operational_channel = "channel",
      configuration = "object",
      parent_revision = "revision",
    },
  },
  enroll_error = composites.error_body,
  session_open = {
    required = { relationship_id = "id", client_nonce = "nonce", child_revision = "revision" },
  },
  session_challenge = {
    required = {
      relationship_id = "id",
      session_id = "id",
      client_nonce = "nonce",
      parent_nonce = "nonce",
      parent_revision = "revision",
    },
  },
  session_confirm = {
    required = {
      relationship_id = "id",
      session_id = "id",
      client_nonce = "nonce",
      parent_nonce = "nonce",
    },
  },
  heartbeat = { required = { connectivity_state = "connectivity_state", revision = "revision" } },
  ack = { required = { acked_request_id = "id" }, optional = { result_revision = "revision" } },
  config_request = { required = { known_revision = "revision" } },
  config_snapshot = {
    required = { revision = "revision", role = "role", configuration = "object" },
    check = function(value)
      return schema.validateAssignment(rawget(value, "role"), rawget(value, "configuration"))
    end,
  },
  dns_query = { required = { name = "string" } },
  dns_result = {
    required = {
      canonical_name = "string",
      customer_network_id = "id",
      computer_id = "id",
      address = "customer_address",
    },
  },
  route_register = {
    required = {
      customer_network_id = "id",
      customer_network_name = "normalized_name",
      router_id = "id",
      router_provider_address = "provider_address",
      isp_id = "id",
      revision = "revision",
    },
  },
  route_remove = { required = { customer_network_id = "id", revision = "revision" } },
  service_request = {
    required = {
      source = "source",
      destination = "destination",
      service = "operation_name",
      payload = "object",
    },
    optional = { source_flow_id = "id", destination_flow_id = "id" },
  },
  service_response = {
    required = { payload = "object" },
    optional = { source_flow_id = "id", destination_flow_id = "id" },
  },
  -- external_call is how a Computer names the External Application in world.
  -- It carries no destination: a service_request destination is scoped to a
  -- Customer Network, and the External Application is not one. The kind itself
  -- is the destination, which is why widening `destination` was the wrong shape
  -- for it. The answer comes back as an ordinary service_response, so a reply
  -- retraces its NAT Flow by exactly one rule regardless of what it answers.
  external_call = {
    required = { source = "source", operation = "operation_name", payload = "object" },
    optional = {
      source_flow_id = "id", access_token = "string",
      device_credential = "string", registration_nonce = "nonce",
    },
    check = function(value)
      return schema.validateCredentialUse(value)
    end,
  },
  error = composites.error_body,
  topology_snapshot = {
    required = {
      revision = "revision",
      world = "object",
      isps = "array",
      routers = "array",
      computers = "array",
      network_statuses = "array",
    },
    check = function(value)
      local total = 0
      for _, field in ipairs({ "isps", "routers", "computers", "network_statuses" }) do
        total = total + #rawget(value, field)
      end
      if total > limits.TOPOLOGY_ENTITIES then
        return false, "topology snapshot exceeds " .. limits.TOPOLOGY_ENTITIES .. " entities", "message_too_large"
      end
      return true
    end,
  },
  topology_change = {
    required = {
      revision = "revision",
      change = "topology_change",
      entity_type = "entity_type",
      entity = "object",
    },
  },
  traffic_batch = {
    required = {
      first_sequence = "positive",
      last_sequence = "positive",
      events = { list = "traffic_event" },
    },
    check = function(value)
      local events = rawget(value, "events")
      if #events > limits.TRAFFIC_BATCH_EVENTS then
        return false, "batch exceeds " .. limits.TRAFFIC_BATCH_EVENTS .. " events", "message_too_large"
      end
      local first = rawget(value, "first_sequence")
      local last = rawget(value, "last_sequence")
      if last < first then return false, "last_sequence precedes first_sequence" end
      if last - first + 1 ~= #events then
        return false, "sequence range does not match the event count"
      end
      return true
    end,
  },
  network_status_set = {
    required = { command_id = "id", customer_network_id = "id", status = "network_status" },
  },
  command_result = {
    required = { command_id = "id", status = "command_status", revision = "revision" },
    optional = { error = "error_body" },
  },
  external_request = {
    required = { ancestry = "ancestry", source_flow_id = "id", operation = "operation_name", payload = "object" },
    optional = { access_token = "string", device_credential = "string", registration_nonce = "nonce" },
    check = function(value)
      return schema.validateCredentialUse(value)
    end,
  },
  external_response = { required = { payload = "object" } },
  admin_command = {
    required = { action = "operation_name", customer_network_id = "id", status = "network_status" },
    check = function(value)
      if rawget(value, "action") ~= "set_network_status" then
        return false, "admin_command permits only set_network_status in v1"
      end
      return true
    end,
  },
}

schema.bodies = bodies

--------------------------------------------------------------------------
-- Transports
--------------------------------------------------------------------------

local function set(...)
  local result = {}
  for _, name in ipairs({ ... }) do result[name] = true end
  return result
end

schema.transports = {
  -- Discovery is unauthenticated by design and answers nothing in detail.
  discovery = set("discover", "offer"),
  -- Handshakes carry an outer proof instead of a session MAC.
  handshake = set("enroll_open", "enroll_challenge", "enroll_confirm", "enroll_accept",
    "enroll_error", "session_open", "session_challenge", "session_confirm"),
  -- Operational frames are MACed under a live session key.
  operational = set("heartbeat", "ack", "config_request", "config_snapshot", "dns_query",
    "dns_result", "route_register", "route_remove", "service_request", "service_response",
    "external_call", "error", "topology_snapshot", "topology_change", "traffic_batch",
    "network_status_set", "command_result"),
  -- The Gateway relies on WSS plus the authenticated session, not a second MAC.
  gateway = set("heartbeat", "ack", "external_request", "external_response", "error",
    "topology_snapshot", "topology_change", "traffic_batch", "admin_command", "command_result"),
}

function schema.isKind(kind)
  return bodies[kind] ~= nil
end

function schema.allows(transport, kind)
  local allowed = schema.transports[transport]
  return allowed ~= nil and allowed[kind] == true
end

--------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------

local validateShape

local function validateRule(rule, value, path)
  if type(rule) == "table" and rule.list then
    if not isArray(value) then return false, path .. " must be an array" end
    for index = 1, #value do
      local ok, message, code = validateRule(rule.list, rawget(value, index), path .. "[" .. index .. "]")
      if not ok then return false, message, code end
    end
    return true
  end
  local scalar = schema.scalars[rule]
  if scalar then
    if not scalar(value) then return false, path .. " is not a valid " .. rule end
    return true
  end
  local composite = composites[rule]
  if composite then
    return validateShape(composite, value, path)
  end
  error("unknown schema rule " .. tostring(rule))
end

function validateShape(shape, value, path)
  if not isObject(value) then return false, path .. " must be an object" end
  for field, rule in pairs(shape.required or {}) do
    local fieldValue = rawget(value, field)
    if fieldValue == nil then
      return false, path .. "." .. field .. " is required"
    end
    local ok, message, code = validateRule(rule, fieldValue, path .. "." .. field)
    if not ok then return false, message, code end
  end
  for field, rule in pairs(shape.optional or {}) do
    local fieldValue = rawget(value, field)
    if fieldValue ~= nil then
      -- An optional field is omitted, never encoded as an empty substitute.
      local ok, message, code = validateRule(rule, fieldValue, path .. "." .. field)
      if not ok then return false, message, code end
    end
  end
  for field in pairs(value) do
    if (shape.required or {})[field] == nil and (shape.optional or {})[field] == nil then
      return false, path .. " has unknown field '" .. tostring(field) .. "'"
    end
  end
  if shape.check then
    local ok, message, code = shape.check(value)
    if not ok then return false, message or (path .. " failed its consistency check"), code end
  end
  return true
end

function schema.validateConfiguration(role, configuration)
  local shape = configurations[role]
  if not shape then return false, "configuration role '" .. tostring(role) .. "' is unknown" end
  return validateShape(shape, configuration, "configuration")
end

-- validateAssignment checks what a parent hands a child, which is narrower than
-- that child's complete configuration wherever the child owns some of it.
function schema.validateAssignment(role, configuration)
  local shape = assignments[role]
  if not shape then return false, "assignment role '" .. tostring(role) .. "' is unknown" end
  return validateShape(shape, configuration, "configuration")
end

-- validateBody returns true, or false plus a message and a stable error code.
function schema.validateBody(kind, body)
  local shape = bodies[kind]
  if not shape then
    return false, "unknown message kind '" .. tostring(kind) .. "'", "invalid_message"
  end
  local ok, message, code = validateShape(shape, body, "body")
  if ok then return true end
  return false, message, code or "invalid_message"
end

schema.validateShape = validateShape
schema.composites = composites

return schema
