-- One-time enrollment tokens.
--
-- An ISP Enrollment Token and a Router Enrollment Token are read off one
-- Computer's screen and typed into another's, so they have to be short enough
-- to type and hard enough to mistype unnoticed. Both are derived from the
-- issuing role's own root secret and a durable counter, which means a parent
-- never stores a secret per token -- it only remembers which counters it has
-- spent.
--
-- The token as typed is the enrollment secret, exactly as a LAN Password is.
-- Deriving it rather than drawing it lets a parent reissue the same token if an
-- Operator loses the screen, and lets it recognise which token was used without
-- keeping any of them.

local internal = ...
local keys = internal("keys")

local tokens = {}

-- Crockford's base32: no I, L, O, or U, so nothing reads as something else.
local ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

-- Eighty bits, which is far more than a one-time secret needs when the parent
-- spends it once and rate limits guesses, and short enough to type.
local TOKEN_BYTES = 10
local TOKEN_LENGTH = 16
local GROUP = 4

tokens.LENGTH = TOKEN_LENGTH

local decodeMap = {}
for index = 1, #ALPHABET do
  decodeMap[ALPHABET:sub(index, index)] = index - 1
end
-- What an Operator is likely to type instead.
decodeMap["I"] = 1
decodeMap["L"] = 1
decodeMap["O"] = 0

local function encode(raw)
  local out = {}
  local buffer, bits = 0, 0
  for index = 1, #raw do
    buffer = buffer * 256 + string.byte(raw, index)
    bits = bits + 8
    while bits >= 5 do
      bits = bits - 5
      local divisor = 2 ^ bits
      local value = math.floor(buffer / divisor) % 32
      out[#out + 1] = ALPHABET:sub(value + 1, value + 1)
      buffer = buffer % divisor
    end
  end
  if bits > 0 then
    local value = (buffer * (2 ^ (5 - bits))) % 32
    out[#out + 1] = ALPHABET:sub(value + 1, value + 1)
  end
  return table.concat(out)
end

-- group renders a token the way it is shown and written down.
local function group(text)
  local pieces = {}
  for index = 1, #text, GROUP do
    pieces[#pieces + 1] = text:sub(index, index + GROUP - 1)
  end
  return table.concat(pieces, "-")
end

tokens.group = group

--------------------------------------------------------------------------
-- Issuing
--------------------------------------------------------------------------

-- issue derives the token for one counter. Calling it twice with the same
-- counter gives the same token, which is what lets an Operator ask to see an
-- outstanding token again without spending a new one.
function tokens.issue(rootSecret, childRole, counter)
  assert(type(rootSecret) == "string" and #rootSecret > 0, "a root secret is required")
  local derived = keys.enrollmentSecret(rootSecret, childRole, counter)
  return tokens.normalize(encode(string.sub(derived, 1, TOKEN_BYTES)))
end

-- display is what goes on a screen: grouped, and unmistakable.
function tokens.display(rootSecret, childRole, counter)
  return group(tokens.issue(rootSecret, childRole, counter))
end

--------------------------------------------------------------------------
-- Reading one back
--------------------------------------------------------------------------

-- normalize accepts what an Operator actually types -- lowercase, spaces,
-- dashes, and the handful of characters that look like others -- and returns
-- the one canonical form, or nil when it is not a token at all.
function tokens.normalize(typed)
  if type(typed) ~= "string" then return nil end
  local cleaned = {}
  for index = 1, #typed do
    local character = string.upper(string.sub(typed, index, index))
    if character ~= "-" and character ~= " " and character ~= "\t" then
      local value = decodeMap[character]
      if value == nil then return nil end
      cleaned[#cleaned + 1] = ALPHABET:sub(value + 1, value + 1)
    end
  end
  local text = table.concat(cleaned)
  if #text ~= TOKEN_LENGTH then return nil end
  return text
end

-- secret is what the enrollment exchange is proved under. The token as typed is
-- the secret, so a Computer that can read the screen can enroll and nothing
-- else has to travel.
function tokens.secret(typed)
  return tokens.normalize(typed)
end

-- matches reports whether a typed token is the one a counter would produce,
-- without the caller having to normalize first.
function tokens.matches(rootSecret, childRole, counter, typed)
  local normalized = tokens.normalize(typed)
  if not normalized then return false end
  return normalized == tokens.issue(rootSecret, childRole, counter)
end

return tokens
