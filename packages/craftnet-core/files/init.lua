-- craftnet-core: pure role state transitions.
--
-- This package is where CraftNet decides things. Address allocation, DNS
-- authority, exact routing, NAT Flow state, Exposed Service policy, Network
-- Status, revisions, stable failures, and redacted Traffic Events all live
-- here, behind one seam:
--
--   engine:handle(input, now) -> { state_changes, effects, result, revision }
--
-- Nothing in this package touches a peripheral, a file, a timer, or the
-- network. An effect is a description of something to do; the runtime does it
-- and reports back by feeding the answer in as the next input. That is what
-- lets the whole of CraftNet's behaviour be tested without Minecraft.

local moduleDirectory = (function()
  local source = debug.getinfo(1, "S").source
  local path = string.match(source, "^@(.*)$") or source
  return string.match(path, "^(.*)[/\\][^/\\]*$") or "."
end)()

local core = {
  name = "craftnet-core",
  version = "0.1.0",
  wireVersion = 1,
}

-- withProtocol binds this package to a craftnet-protocol instance. The
-- dependency is injected rather than located, because core performs no file
-- access of its own -- not even to find its own sibling package. A composition
-- root calls this once.
function core.withProtocol(protocol)
  assert(type(protocol) == "table" and type(protocol.validate) == "table",
    "craftnet-core requires the craftnet-protocol package")
  assert(protocol.wireVersion == core.wireVersion,
    "craftnet-core speaks wire version " .. core.wireVersion
    .. " but was given protocol wire version " .. tostring(protocol.wireVersion))

  local loaded = { protocol = protocol }
  local loading = {}

  local function internal(name)
    local cached = loaded[name]
    if cached ~= nil then return cached end
    assert(not loading[name], "circular core module dependency at '" .. name .. "'")
    loading[name] = true
    local chunk, loadError = loadfile(moduleDirectory .. "/" .. name .. ".lua")
    assert(chunk, "craftnet-core cannot load module '" .. name .. "': " .. tostring(loadError))
    local module = chunk(internal)
    loading[name] = nil
    loaded[name] = module
    return module
  end

  local engine = internal("engine")
  local events = internal("events")
  local flows = internal("flows")

  local api = {
    name = core.name,
    version = core.version,
    wireVersion = core.wireVersion,

    -- newEngine creates a role engine from durable state.
    newEngine = engine.new,

    -- Value constructors, so a caller building a payload need not reach into
    -- the protocol package for them.
    object = protocol.object,
    array = protocol.array,
    null = protocol.null,

    errors = protocol.errors,

    -- Limits that belong to this layer rather than to the wire.
    limits = {
      FLOW_IDLE_MS = flows.IDLE_MS,
      EVENT_BUFFER = events.CAPACITY,
    },

    -- Exposed for tests and for the runtime's own screens; these are pure
    -- helpers, not authority.
    ipv4 = internal("ipv4"),
    names = internal("names"),
    events = events,
  }
  return api
end

return core
