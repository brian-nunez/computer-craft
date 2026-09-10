-- craftnet-central: a CraftNet role.
--
-- A role package is a composition root, not a layer. It wires craftnet-protocol,
-- craftnet-core, and craftnet-runtime together and supplies what is genuinely
-- its own. It must not grow a second implementation of protocol, persistence,
-- or routing behaviour.

local moduleDirectory = (function()
  local source = debug.getinfo(1, "S").source
  local path = string.match(source, "^@(.*)$") or source
  return string.match(path, "^(.*)[/\\][^/\\]*$") or "."
end)()

local package = {
  name = "craftnet-central",
  version = "0.1.0",
  wireVersion = 1,
}

function package.withPackages(packages)
  assert(type(packages) == "table", "craftnet-central needs its dependencies")
  local protocol = packages.protocol
  local core = packages.core
  local runtime = packages.runtime
  assert(type(protocol) == "table" and type(protocol.validate) == "table",
    "craftnet-central requires the craftnet-protocol package")
  assert(type(core) == "table" and type(core.newEngine) == "function",
    "craftnet-central requires a craftnet-core bound to that protocol")
  assert(type(runtime) == "table" and type(runtime.new) == "function",
    "craftnet-central requires a craftnet-runtime bound to that core")
  assert(protocol.wireVersion == package.wireVersion,
    "craftnet-central speaks wire version " .. package.wireVersion
    .. " but was given protocol wire version " .. tostring(protocol.wireVersion))

  local loaded = { protocol = protocol, core = core, runtime = runtime }
  local loading = {}

  local function internal(name)
    local cached = loaded[name]
    if cached ~= nil then return cached end
    assert(not loading[name], "circular module dependency at '" .. name .. "'")
    loading[name] = true
    local chunk, loadError = loadfile(moduleDirectory .. "/" .. name .. ".lua")
    assert(chunk, "craftnet-central cannot load module '" .. name .. "': " .. tostring(loadError))
    local module = chunk(internal)
    loading[name] = nil
    loaded[name] = module
    return module
  end

  local central = internal("central")
  local api = {
    name = package.name,
    version = package.version,
    wireVersion = package.wireVersion,
    new = central.new,
    wizard = internal("wizard"),
  }
  for key, value in pairs(central) do
    if api[key] == nil and key ~= "new" then api[key] = value end
  end
  return api
end

return package
