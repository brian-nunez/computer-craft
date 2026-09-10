-- Portable 32-bit word operations.
--
-- CC:Tweaked runs Lua 5.2 and supplies bit32; the repository's test hosts run
-- newer interpreters that removed it. Native bitwise operators are deliberately
-- absent from this file so it parses on every supported host, and the fallback
-- combines nibbles through precomputed tables rather than looping over 32 bits.

local bitops = {}

local MODULUS = 4294967296
local native = rawget(_G, "bit32")

local function mask(value)
  return value % MODULUS
end

bitops.mask = mask

local xorNibble = {}
local andNibble = {}
local orNibble = {}

for left = 0, 15 do
  xorNibble[left] = {}
  andNibble[left] = {}
  orNibble[left] = {}
  for right = 0, 15 do
    local exclusive, conjunction, disjunction = 0, 0, 0
    local leftValue, rightValue, weight = left, right, 1
    for _ = 1, 4 do
      local leftBit = leftValue % 2
      local rightBit = rightValue % 2
      if leftBit ~= rightBit then exclusive = exclusive + weight end
      if leftBit == 1 and rightBit == 1 then conjunction = conjunction + weight end
      if leftBit == 1 or rightBit == 1 then disjunction = disjunction + weight end
      leftValue = (leftValue - leftBit) / 2
      rightValue = (rightValue - rightBit) / 2
      weight = weight * 2
    end
    xorNibble[left][right] = exclusive
    andNibble[left][right] = conjunction
    orNibble[left][right] = disjunction
  end
end

local function combine(lookup, left, right)
  left = mask(left)
  right = mask(right)
  local result, weight = 0, 1
  for _ = 1, 8 do
    result = result + lookup[left % 16][right % 16] * weight
    left = math.floor(left / 16)
    right = math.floor(right / 16)
    weight = weight * 16
  end
  return result
end

if native then
  function bitops.bxor(left, right) return native.bxor(left, right) end
  function bitops.band(left, right) return native.band(left, right) end
  function bitops.bor(left, right) return native.bor(left, right) end
  function bitops.bnot(value) return native.bnot(value) end
  function bitops.rshift(value, count) return native.rshift(value, count) end
  function bitops.lshift(value, count) return native.lshift(value, count) end
  function bitops.rrotate(value, count) return native.rrotate(value, count) end
else
  function bitops.bxor(left, right) return combine(xorNibble, left, right) end
  function bitops.band(left, right) return combine(andNibble, left, right) end
  function bitops.bor(left, right) return combine(orNibble, left, right) end

  function bitops.bnot(value)
    return MODULUS - 1 - mask(value)
  end

  function bitops.rshift(value, count)
    if count >= 32 then return 0 end
    return math.floor(mask(value) / (2 ^ count))
  end

  function bitops.lshift(value, count)
    if count >= 32 then return 0 end
    return mask(mask(value) * (2 ^ count))
  end

  function bitops.rrotate(value, count)
    count = count % 32
    if count == 0 then return mask(value) end
    value = mask(value)
    local divisor = 2 ^ count
    local low = value % divisor
    return math.floor(value / divisor) + low * (2 ^ (32 - count))
  end
end

-- add32 sums any number of words without leaving the exact integer range.
function bitops.add32(...)
  local total = 0
  local count = select("#", ...)
  for index = 1, count do
    total = (total + select(index, ...)) % MODULUS
  end
  return total
end

return bitops
