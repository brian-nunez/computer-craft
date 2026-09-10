-- HMAC-SHA-256 and the CraftNet key derivation rooted in it.
--
-- Derivation labels are purpose separated so that a relationship credential can
-- never be replayed as a session key or as a nonce.

local internal = ...
local sha256 = internal("sha256")
local bitops = internal("bitops")

local hmac = {}

local BLOCK_SIZE = 64

local function blockKey(key)
  if #key > BLOCK_SIZE then key = sha256.bytes(key) end
  return key .. string.rep("\0", BLOCK_SIZE - #key)
end

local function padWith(key, constant)
  local pieces = {}
  for index = 1, BLOCK_SIZE do
    pieces[index] = string.char(bitops.bxor(string.byte(key, index), constant))
  end
  return table.concat(pieces)
end

-- bytes returns the raw MAC so derivation can chain without hex round trips.
function hmac.bytes(key, message)
  assert(type(key) == "string", "hmac key must be a byte string")
  assert(type(message) == "string", "hmac message must be a byte string")
  local prepared = blockKey(key)
  local inner = sha256.bytes(padWith(prepared, 0x36) .. message)
  return sha256.bytes(padWith(prepared, 0x5c) .. inner)
end

function hmac.hex(key, message)
  return sha256.toHex(hmac.bytes(key, message))
end

-- equals compares MACs without an early exit so that a mismatch position is not
-- observable through timing on a busy Computer.
function hmac.equals(left, right)
  if type(left) ~= "string" or type(right) ~= "string" or #left ~= #right then
    return false
  end
  local difference = 0
  for index = 1, #left do
    difference = bitops.bor(difference, bitops.bxor(string.byte(left, index), string.byte(right, index)))
  end
  return difference == 0
end

return hmac
