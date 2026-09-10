-- CraftNet Canonical JSON 1.
--
-- CJ1 is both the strict wire decoder and the only representation ever handed
-- to HMAC. Decoding rejects everything the canonical form cannot round trip --
-- duplicate keys, fractional numbers, values outside the exact integer range,
-- unescaped control characters, and invalid UTF-8 -- so that a signature always
-- covers exactly the bytes a peer validated.

local internal = ...
local limits = internal("limits")

local cj1 = {}

local EXACT_INTEGER_MAXIMUM = 9007199254740991

-- null is a sentinel because Lua cannot store nil inside a table; using it also
-- keeps decoded arrays free of holes.
cj1.null = setmetatable({}, { __tostring = function() return "cj1.null" end })

local arrayTag = { kind = "array" }
local objectTag = { kind = "object" }

function cj1.array(values)
  return setmetatable(values or {}, arrayTag)
end

function cj1.object(values)
  return setmetatable(values or {}, objectTag)
end

function cj1.isArray(value)
  return getmetatable(value) == arrayTag
end

function cj1.isObject(value)
  return getmetatable(value) == objectTag
end

--------------------------------------------------------------------------
-- Shared helpers
--------------------------------------------------------------------------

local function isExactInteger(value)
  return type(value) == "number"
    and value == value                       -- rejects NaN
    and value - value == 0                   -- rejects infinities
    and math.floor(value) == value
    and value <= EXACT_INTEGER_MAXIMUM
    and value >= -EXACT_INTEGER_MAXIMUM
end

cj1.isExactInteger = isExactInteger

-- byteLess sorts by unsigned UTF-8 byte order. Lua's own string comparison
-- consults the C locale, which would make canonical output host dependent.
local function byteLess(left, right)
  local shortest = #left
  if #right < shortest then shortest = #right end
  for index = 1, shortest do
    local leftByte = string.byte(left, index)
    local rightByte = string.byte(right, index)
    if leftByte ~= rightByte then return leftByte < rightByte end
  end
  return #left < #right
end

cj1.byteLess = byteLess

-- validUtf8 rejects overlong encodings, surrogates, and out-of-range scalars so
-- that a decoded string is safe to re-emit verbatim.
local function validUtf8(text)
  local index, length = 1, #text
  while index <= length do
    local first = string.byte(text, index)
    local continuationCount, codePoint, minimum
    if first < 0x80 then
      index = index + 1
      continuationCount = 0
    elseif first >= 0xc2 and first <= 0xdf then
      continuationCount, codePoint, minimum = 1, first - 0xc0, 0x80
    elseif first >= 0xe0 and first <= 0xef then
      continuationCount, codePoint, minimum = 2, first - 0xe0, 0x800
    elseif first >= 0xf0 and first <= 0xf4 then
      continuationCount, codePoint, minimum = 3, first - 0xf0, 0x10000
    else
      return false
    end
    if continuationCount > 0 then
      if index + continuationCount > length then return false end
      for offset = 1, continuationCount do
        local continuation = string.byte(text, index + offset)
        if continuation < 0x80 or continuation > 0xbf then return false end
        codePoint = codePoint * 64 + (continuation - 0x80)
      end
      if codePoint < minimum then return false end
      if codePoint >= 0xd800 and codePoint <= 0xdfff then return false end
      if codePoint > 0x10ffff then return false end
      index = index + continuationCount + 1
    end
  end
  return true
end

cj1.validUtf8 = validUtf8

local function encodeCodePoint(codePoint)
  if codePoint < 0x80 then
    return string.char(codePoint)
  elseif codePoint < 0x800 then
    return string.char(0xc0 + math.floor(codePoint / 64), 0x80 + codePoint % 64)
  elseif codePoint < 0x10000 then
    return string.char(
      0xe0 + math.floor(codePoint / 4096),
      0x80 + math.floor(codePoint / 64) % 64,
      0x80 + codePoint % 64)
  end
  return string.char(
    0xf0 + math.floor(codePoint / 262144),
    0x80 + math.floor(codePoint / 4096) % 64,
    0x80 + math.floor(codePoint / 64) % 64,
    0x80 + codePoint % 64)
end

--------------------------------------------------------------------------
-- Decoding
--------------------------------------------------------------------------

local Decoder = {}
Decoder.__index = Decoder

local function fail(message)
  error({ craftnet = true, code = "invalid_message", message = message }, 0)
end

local function failLarge(message)
  error({ craftnet = true, code = "message_too_large", message = message }, 0)
end

function Decoder:peek()
  return string.sub(self.text, self.position, self.position)
end

function Decoder:skipWhitespace()
  local _, stop = string.find(self.text, "^[ \t\n\r]*", self.position)
  self.position = stop + 1
end

function Decoder:expect(character)
  if self:peek() ~= character then
    fail("expected '" .. character .. "' at byte " .. self.position)
  end
  self.position = self.position + 1
end

function Decoder:parseString()
  self:expect('"')
  local pieces = {}
  while true do
    local character = self:peek()
    if character == "" then fail("unterminated string") end
    local byte = string.byte(character)
    if byte < 0x20 then
      fail("unescaped control character in string")
    elseif character == '"' then
      self.position = self.position + 1
      break
    elseif character == "\\" then
      self.position = self.position + 1
      local escape = self:peek()
      self.position = self.position + 1
      if escape == '"' then pieces[#pieces + 1] = '"'
      elseif escape == "\\" then pieces[#pieces + 1] = "\\"
      elseif escape == "/" then pieces[#pieces + 1] = "/"
      elseif escape == "b" then pieces[#pieces + 1] = "\b"
      elseif escape == "f" then pieces[#pieces + 1] = "\f"
      elseif escape == "n" then pieces[#pieces + 1] = "\n"
      elseif escape == "r" then pieces[#pieces + 1] = "\r"
      elseif escape == "t" then pieces[#pieces + 1] = "\t"
      elseif escape == "u" then
        local digits = string.sub(self.text, self.position, self.position + 3)
        if not string.match(digits, "^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
          fail("malformed \\u escape")
        end
        self.position = self.position + 4
        local codePoint = tonumber(digits, 16)
        if codePoint >= 0xd800 and codePoint <= 0xdbff then
          if string.sub(self.text, self.position, self.position + 1) ~= "\\u" then
            fail("high surrogate without a low surrogate")
          end
          local trailing = string.sub(self.text, self.position + 2, self.position + 5)
          if not string.match(trailing, "^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
            fail("malformed low surrogate escape")
          end
          local low = tonumber(trailing, 16)
          if low < 0xdc00 or low > 0xdfff then fail("invalid low surrogate") end
          self.position = self.position + 6
          codePoint = 0x10000 + (codePoint - 0xd800) * 0x400 + (low - 0xdc00)
        elseif codePoint >= 0xdc00 and codePoint <= 0xdfff then
          fail("unpaired low surrogate")
        end
        pieces[#pieces + 1] = encodeCodePoint(codePoint)
      else
        fail("unknown escape sequence")
      end
    else
      local nextEscape = string.find(self.text, '["\\]', self.position)
      local stop = (nextEscape or (#self.text + 1)) - 1
      local controlStart = string.find(self.text, "[%z\1-\31]", self.position)
      if controlStart and controlStart <= stop then stop = controlStart - 1 end
      pieces[#pieces + 1] = string.sub(self.text, self.position, stop)
      self.position = stop + 1
    end
  end
  local value = table.concat(pieces)
  if #value > self.limits.stringBytes then
    failLarge("string exceeds " .. self.limits.stringBytes .. " bytes")
  end
  if not validUtf8(value) then fail("string is not valid UTF-8") end
  return value
end

function Decoder:parseNumber()
  local literal = string.match(self.text, "^%-?[0-9]+", self.position)
  if not literal then fail("malformed number at byte " .. self.position) end
  if string.match(literal, "^%-?0[0-9]") then fail("number has a leading zero") end
  self.position = self.position + #literal
  local trailing = self:peek()
  if trailing == "." or trailing == "e" or trailing == "E" then
    fail("fractional and exponent numbers are not canonical")
  end
  local value = tonumber(literal)
  if not isExactInteger(value) then
    fail("number is outside the exact integer range")
  end
  return value
end

function Decoder:parseValue(depth)
  if depth > self.limits.depth then
    failLarge("nesting exceeds depth " .. self.limits.depth)
  end
  self:skipWhitespace()
  local character = self:peek()
  if character == "" then fail("unexpected end of input") end
  if character == "{" then return self:parseObject(depth) end
  if character == "[" then return self:parseArray(depth) end
  if character == '"' then return self:parseString() end
  if character == "-" or (character >= "0" and character <= "9") then return self:parseNumber() end
  if string.sub(self.text, self.position, self.position + 3) == "true" then
    self.position = self.position + 4
    return true
  end
  if string.sub(self.text, self.position, self.position + 4) == "false" then
    self.position = self.position + 5
    return false
  end
  if string.sub(self.text, self.position, self.position + 3) == "null" then
    self.position = self.position + 4
    return cj1.null
  end
  fail("unexpected token at byte " .. self.position)
end

function Decoder:parseObject(depth)
  self:expect("{")
  local result = cj1.object()
  local count = 0
  self:skipWhitespace()
  if self:peek() == "}" then
    self.position = self.position + 1
    return result
  end
  while true do
    self:skipWhitespace()
    local key = self:parseString()
    if rawget(result, key) ~= nil then
      fail("duplicate object key " .. string.format("%q", key))
    end
    count = count + 1
    if count > self.limits.objectKeys then
      failLarge("object exceeds " .. self.limits.objectKeys .. " keys")
    end
    self:skipWhitespace()
    self:expect(":")
    rawset(result, key, self:parseValue(depth + 1))
    self:skipWhitespace()
    local character = self:peek()
    if character == "," then
      self.position = self.position + 1
    elseif character == "}" then
      self.position = self.position + 1
      break
    else
      fail("expected ',' or '}' at byte " .. self.position)
    end
  end
  return result
end

function Decoder:parseArray(depth)
  self:expect("[")
  local result = cj1.array()
  local count = 0
  self:skipWhitespace()
  if self:peek() == "]" then
    self.position = self.position + 1
    return result
  end
  while true do
    count = count + 1
    if count > self.limits.arrayElements then
      failLarge("array exceeds " .. self.limits.arrayElements .. " elements")
    end
    rawset(result, count, self:parseValue(depth + 1))
    self:skipWhitespace()
    local character = self:peek()
    if character == "," then
      self.position = self.position + 1
    elseif character == "]" then
      self.position = self.position + 1
      break
    else
      fail("expected ',' or ']' at byte " .. self.position)
    end
  end
  return result
end

-- decode returns the value, or nil plus a stable error code and message.
function cj1.decode(text, options)
  if type(text) ~= "string" then
    return nil, "invalid_message", "input must be a string"
  end
  options = options or {}
  local decoder = setmetatable({
    text = text,
    position = 1,
    limits = limits.resolve(options),
  }, Decoder)

  local ok, result = pcall(function()
    local value = decoder:parseValue(1)
    decoder:skipWhitespace()
    if decoder.position <= #text then fail("trailing data after the top-level value") end
    return value
  end)

  if ok then return result end
  if type(result) == "table" and result.craftnet then
    return nil, result.code, result.message
  end
  return nil, "invalid_message", tostring(result)
end

--------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\" }
local hexDigits = "0123456789abcdef"

for byte = 0, 31 do
  local high = math.floor(byte / 16) + 1
  local low = (byte % 16) + 1
  escapes[string.char(byte)] = "\\u00" .. hexDigits:sub(high, high) .. hexDigits:sub(low, low)
end

local function encodeString(value)
  if not validUtf8(value) then fail("string is not valid UTF-8") end
  return '"' .. string.gsub(value, '[%z\1-\31"\\]', escapes) .. '"'
end

local function encodeInteger(value)
  if not isExactInteger(value) then
    fail("only exact integers are canonical")
  end
  return string.format("%d", value)
end

-- classify decides array or object for a table, preferring an explicit tag and
-- otherwise refusing anything ambiguous rather than guessing.
local function classify(value)
  local tag = getmetatable(value)
  if tag == arrayTag then return "array" end
  if tag == objectTag then return "object" end
  if next(value) == nil then return "object" end
  local hasStringKey, hasNumberKey = false, false
  for key in pairs(value) do
    if type(key) == "string" then
      hasStringKey = true
    elseif type(key) == "number" then
      hasNumberKey = true
    else
      fail("object keys must be strings")
    end
  end
  if hasStringKey and hasNumberKey then fail("mixed table keys are not canonical") end
  if hasNumberKey then return "array" end
  return "object"
end

local encodeValue

local function encodeArray(value, depth, pieces)
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or math.floor(key) ~= key or key < 1 then
      fail("sparse or non-sequential arrays are not canonical")
    end
    count = count + 1
  end
  for index = 1, count do
    if rawget(value, index) == nil then
      fail("sparse or non-sequential arrays are not canonical")
    end
  end
  pieces[#pieces + 1] = "["
  for index = 1, count do
    if index > 1 then pieces[#pieces + 1] = "," end
    encodeValue(rawget(value, index), depth + 1, pieces)
  end
  pieces[#pieces + 1] = "]"
end

local function encodeObject(value, depth, pieces)
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then fail("object keys must be strings") end
    keys[#keys + 1] = key
  end
  table.sort(keys, byteLess)
  pieces[#pieces + 1] = "{"
  for index = 1, #keys do
    if index > 1 then pieces[#pieces + 1] = "," end
    pieces[#pieces + 1] = encodeString(keys[index])
    pieces[#pieces + 1] = ":"
    encodeValue(rawget(value, keys[index]), depth + 1, pieces)
  end
  pieces[#pieces + 1] = "}"
end

function encodeValue(value, depth, pieces)
  if depth > limits.DEPTH then
    failLarge("nesting exceeds depth " .. limits.DEPTH)
  end
  if value == cj1.null then
    pieces[#pieces + 1] = "null"
  elseif type(value) == "boolean" then
    pieces[#pieces + 1] = value and "true" or "false"
  elseif type(value) == "number" then
    pieces[#pieces + 1] = encodeInteger(value)
  elseif type(value) == "string" then
    pieces[#pieces + 1] = encodeString(value)
  elseif type(value) == "table" then
    if classify(value) == "array" then
      encodeArray(value, depth, pieces)
    else
      encodeObject(value, depth, pieces)
    end
  else
    fail("values of type " .. type(value) .. " are not canonical")
  end
end

-- classify is exported so that validation applies exactly the encoder's own
-- array/object rules: a caller may hand over a plain Lua table and still be
-- judged by the form that would actually be signed.
function cj1.classify(value)
  if type(value) ~= "table" or value == cj1.null then return nil end
  local ok, kind = pcall(classify, value)
  if not ok then return nil end
  return kind
end

-- encode returns the canonical text, or nil plus a stable error code.
function cj1.encode(value)
  local pieces = {}
  local ok, result = pcall(encodeValue, value, 1, pieces)
  if ok then return table.concat(pieces) end
  if type(result) == "table" and result.craftnet then
    return nil, result.code, result.message
  end
  return nil, "invalid_message", tostring(result)
end

-- mustEncode is for internal call sites that have already validated their input
-- and must not silently sign a partial structure.
function cj1.mustEncode(value)
  local text, code, message = cj1.encode(value)
  if not text then error(code .. ": " .. tostring(message), 2) end
  return text
end

return cj1
