-- craftnet-runtime: one configured role, running.
--
-- This is the only CraftNet package that performs I/O. It owns the CraftOS
-- event loop, the parent and child link lifecycle, reconnect backoff, atomic
-- versioned snapshots with one backup, effect execution, the Traffic Event
-- buffers, and the terse status screen.
--
-- Everything it touches arrives as an injected adapter -- clock, storage,
-- links, screen, and for the Central Server a gateway -- so a whole World can
-- be driven with fakes while still exercising the real state transitions in
-- craftnet-core.

local moduleDirectory = (function()
  local source = debug.getinfo(1, "S").source
  local path = string.match(source, "^@(.*)$") or source
  return string.match(path, "^(.*)[/\\][^/\\]*$") or "."
end)()

local runtimePackage = {
  name = "craftnet-runtime",
  version = "0.1.0",
  wireVersion = 1,
}

-- withPackages binds this package to its dependencies. Like craftnet-core, the
-- runtime is handed what it needs rather than locating it, so a composition
-- root stays the only place that knows where anything lives.
function runtimePackage.withPackages(packages)
  assert(type(packages) == "table", "the runtime needs its dependencies")
  local protocol = packages.protocol
  local core = packages.core
  assert(type(protocol) == "table" and type(protocol.validate) == "table",
    "craftnet-runtime requires the craftnet-protocol package")
  assert(type(core) == "table" and type(core.newEngine) == "function",
    "craftnet-runtime requires a craftnet-core bound to that protocol")
  assert(protocol.wireVersion == runtimePackage.wireVersion,
    "craftnet-runtime speaks wire version " .. runtimePackage.wireVersion
    .. " but was given protocol wire version " .. tostring(protocol.wireVersion))

  local loaded = { protocol = protocol, core = core }
  local loading = {}

  local function internal(name)
    local cached = loaded[name]
    if cached ~= nil then return cached end
    assert(not loading[name], "circular runtime module dependency at '" .. name .. "'")
    loading[name] = true
    local chunk, loadError = loadfile(moduleDirectory .. "/" .. name .. ".lua")
    assert(chunk, "craftnet-runtime cannot load module '" .. name .. "': " .. tostring(loadError))
    local module = chunk(internal)
    loading[name] = nil
    loaded[name] = module
    return module
  end

  local runtime = internal("runtime")
  local connectivity = internal("connectivity")
  local snapshot = internal("snapshot")
  local secrets = internal("secrets")
  local screen = internal("screen")
  local links = internal("links")
  local enroll = internal("enroll")

  return {
    name = runtimePackage.name,
    version = runtimePackage.version,
    wireVersion = runtimePackage.wireVersion,

    -- new builds a runtime for one role.
    new = function(options) return runtime.new(core, options) end,

    -- The pieces a composition root or a test may want on their own.
    snapshot = snapshot,
    secrets = secrets,
    connectivity = connectivity,
    screen = screen,

    -- newLinks builds the session-carrying links adapter over any transport,
    -- which is what makes a whole vertical slice testable without a modem.
    newLinks = links.new,

    -- enroll is the parent-child exchange every boundary in CraftNet shares.
    -- A role package supplies only what is its own: which secrets are valid,
    -- what to assign, and what to do with the credential that comes out.
    enroll = enroll,

    -- The real CraftOS adapters. They are the only files in CraftNet that
    -- reference fs, os, or peripheral, and they are loaded on demand so that a
    -- test host without those globals can still use the runtime.
    adapters = {
      storage = function(root) return internal("adapter_storage").new(root) end,
      clock = function() return internal("adapter_clock").new() end,
      screen = function(target) return internal("adapter_screen").new(target) end,
      modem = function(options) return internal("adapter_modem").new(options) end,
    },

    limits = {
      HEARTBEAT_MS = connectivity.HEARTBEAT_MS,
      DISCONNECT_MS = connectivity.DISCONNECT_MS,
      BACKOFF_FIRST_MS = connectivity.BACKOFF_FIRST_MS,
      BACKOFF_LIMIT_MS = connectivity.BACKOFF_LIMIT_MS,
    },
  }
end

return runtimePackage
