-- Reads the cross-language protocol fixture catalog for the Lua suite.
--
-- The catalog under spec/protocol/v1 is the executable compatibility source of
-- truth. Fixture files are decoded with the protocol package's own strict
-- decoder, so reading the catalog exercises the decoder before a single case
-- runs.

local catalog = {}

local ROOT = "spec/protocol/v1"

catalog.root = ROOT
catalog.protocol = dofile("packages/craftnet-protocol/files/init.lua")

local cj1 = catalog.protocol.conformance.cj1

local function readFile(path)
  local handle, openError = io.open(path, "rb")
  assert(handle, "cannot read fixture " .. path .. ": " .. tostring(openError))
  local contents = assert(handle:read("*a"))
  assert(handle:close())
  return contents
end

-- load decodes one fixture file. The catalog is authored to stay inside the wire
-- limits so that it can be read back by the same strict decoder it exercises.
function catalog.load(relative)
  local value, code, message = cj1.decode(readFile(ROOT .. "/" .. relative))
  assert(value, "fixture " .. relative .. " failed to decode: "
    .. tostring(code) .. " " .. tostring(message))
  return value
end

-- consumers reports whether the Lua implementation must replay a fixture.
function catalog.replayedByLua(entry)
  for _, consumer in ipairs(rawget(entry, "consumers")) do
    if consumer == "lua" then return true end
  end
  return false
end

function catalog.field(object, key)
  local value = rawget(object, key)
  assert(value ~= nil, "fixture is missing field '" .. key .. "'")
  return value
end

local hexDigits = "0123456789abcdef"

function catalog.fromHex(text)
  return catalog.protocol.conformance.sha256.fromHex(text)
end

function catalog.toHex(raw)
  return catalog.protocol.conformance.sha256.toHex(raw)
end

function catalog.hexOf(byte)
  local high = math.floor(byte / 16) + 1
  local low = (byte % 16) + 1
  return hexDigits:sub(high, high) .. hexDigits:sub(low, low)
end

return catalog
