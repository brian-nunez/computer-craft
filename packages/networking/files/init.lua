local function loadDependency(name, file)
  local handle = assert(fs.open("/.ccpm/lock.json", "r"), "ccpm lock file not found")
  local lock = textutils.unserialiseJSON(handle.readAll())
  handle.close()
  local entry = lock and lock.packages and lock.packages[name]
  assert(entry, "missing dependency: " .. name)
  return dofile("/.ccpm/packages/" .. name .. "/" .. entry.version .. "/" .. file)
end

local discovery = loadDependency("peripheral-discovery", "init.lua")
local networking = {}
local PRIORITY = { ender = 1, wired = 2, wireless = 3 }

local function classify(device, options)
  local configured = options.kinds and options.kinds[device.name]
  if configured then
    assert(PRIORITY[configured], "invalid modem kind for " .. device.name .. ": " .. configured)
    return configured
  end
  if device.types.ender_modem or device.types.enderModem
      or device.name:lower():find("ender", 1, true) then
    return "ender"
  end
  local ok, wireless = pcall(device.wrapped.isWireless)
  if not ok then return nil end
  return wireless and "wireless" or "wired"
end

function networking.modems(options)
  options = options or {}
  local result = discovery.modems()
  for _, device in ipairs(result) do device.kind = classify(device, options) end
  table.sort(result, function(a, b)
    local ap, bp = PRIORITY[a.kind] or 99, PRIORITY[b.kind] or 99
    return ap == bp and a.name < b.name or ap < bp
  end)
  return result
end

function networking.selectModem(options)
  return networking.modems(options)[1]
end

function networking.monitors()
  return discovery.monitors()
end

return networking
