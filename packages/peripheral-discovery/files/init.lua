local discovery = {}

local function packed(fn, ...)
  return table.pack(fn(...))
end

local function toSet(items)
  local result = {}
  for index = 1, items.n or #items do
    if items[index] ~= nil then result[items[index]] = true end
  end
  return result
end

function discovery.scan()
  local devices = {}
  for _, name in ipairs(peripheral.getNames()) do
    local types = packed(peripheral.getType, name)
    devices[#devices + 1] = {
      name = name,
      type = types[1],
      types = toSet(types),
      methods = toSet(peripheral.getMethods(name) or {}),
      wrapped = peripheral.wrap(name),
    }
  end
  table.sort(devices, function(a, b) return a.name < b.name end)
  return devices
end

function discovery.findAll(wanted, devices)
  local matches = {}
  for _, device in ipairs(devices or discovery.scan()) do
    if device.types[wanted] then matches[#matches + 1] = device end
  end
  return matches
end

function discovery.modems(devices) return discovery.findAll("modem", devices) end
function discovery.monitors(devices) return discovery.findAll("monitor", devices) end

function discovery.watch(callback)
  callback(discovery.scan())
  while true do
    local event, name = os.pullEvent()
    if event == "peripheral" or event == "peripheral_detach" then
      callback(discovery.scan(), event, name)
    end
  end
end

return discovery
