-- SHA-256 over byte strings.
--
-- CC:Tweaked exposes no hashing API, so CraftNet carries its own FIPS 180-4
-- implementation. Callers outside craftnet-protocol never invoke it directly.

local internal = ...
local bitops = internal("bitops")

local sha256 = {}

local bxor, band, bnot = bitops.bxor, bitops.band, bitops.bnot
local rshift, rrotate, add32 = bitops.rshift, bitops.rrotate, bitops.add32

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local INITIAL = {
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local function packWord(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256)
end

local function pad(message)
  local length = #message
  local bitLengthLow = (length % 536870912) * 8
  local bitLengthHigh = math.floor(length / 536870912)
  local suffix = "\128" .. string.rep("\0", (55 - length) % 64)
  return message .. suffix .. packWord(bitLengthHigh) .. packWord(bitLengthLow)
end

-- bytes returns the raw 32-byte digest so HMAC can chain without re-decoding.
function sha256.bytes(message)
  assert(type(message) == "string", "sha256 requires a byte string")

  local h1, h2, h3, h4 = INITIAL[1], INITIAL[2], INITIAL[3], INITIAL[4]
  local h5, h6, h7, h8 = INITIAL[5], INITIAL[6], INITIAL[7], INITIAL[8]

  local padded = pad(message)
  local schedule = {}

  for blockStart = 1, #padded, 64 do
    for index = 1, 16 do
      local offset = blockStart + (index - 1) * 4
      local a, b, c, d = string.byte(padded, offset, offset + 3)
      schedule[index] = ((a * 256 + b) * 256 + c) * 256 + d
    end

    for index = 17, 64 do
      local previous = schedule[index - 15]
      local recent = schedule[index - 2]
      local s0 = bxor(bxor(rrotate(previous, 7), rrotate(previous, 18)), rshift(previous, 3))
      local s1 = bxor(bxor(rrotate(recent, 17), rrotate(recent, 19)), rshift(recent, 10))
      schedule[index] = add32(schedule[index - 16], s0, schedule[index - 7], s1)
    end

    local a, b, c, d, e, f, g, h = h1, h2, h3, h4, h5, h6, h7, h8

    for index = 1, 64 do
      local sigma1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
      local choose = bxor(band(e, f), band(bnot(e), g))
      local temp1 = add32(h, sigma1, choose, K[index], schedule[index])
      local sigma0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
      local majority = bxor(bxor(band(a, b), band(a, c)), band(b, c))
      local temp2 = add32(sigma0, majority)

      h = g
      g = f
      f = e
      e = add32(d, temp1)
      d = c
      c = b
      b = a
      a = add32(temp1, temp2)
    end

    h1 = add32(h1, a)
    h2 = add32(h2, b)
    h3 = add32(h3, c)
    h4 = add32(h4, d)
    h5 = add32(h5, e)
    h6 = add32(h6, f)
    h7 = add32(h7, g)
    h8 = add32(h8, h)
  end

  return packWord(h1) .. packWord(h2) .. packWord(h3) .. packWord(h4)
    .. packWord(h5) .. packWord(h6) .. packWord(h7) .. packWord(h8)
end

local hexDigits = "0123456789abcdef"

-- toHex renders lowercase hexadecimal without string.format so that a host
-- with integer subtypes cannot change the output.
function sha256.toHex(raw)
  local pieces = {}
  for index = 1, #raw do
    local value = string.byte(raw, index)
    local high = math.floor(value / 16) + 1
    local low = (value % 16) + 1
    pieces[index] = hexDigits:sub(high, high) .. hexDigits:sub(low, low)
  end
  return table.concat(pieces)
end

function sha256.fromHex(text)
  assert(type(text) == "string" and #text % 2 == 0, "hexadecimal input must have an even length")
  local pieces = {}
  for index = 1, #text, 2 do
    local pair = text:sub(index, index + 1)
    local value = tonumber(pair, 16)
    assert(value and pair:match("^[0-9a-f][0-9a-f]$"), "invalid lowercase hexadecimal input")
    pieces[#pieces + 1] = string.char(value)
  end
  return table.concat(pieces)
end

function sha256.hex(message)
  return sha256.toHex(sha256.bytes(message))
end

return sha256
