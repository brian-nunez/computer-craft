-- IPv4 arithmetic for address pools and Provider Allocations.
--
-- CraftNet does not route by prefix. Ranges organize allocation only: the
-- Central Server hands each ISP a disjoint block so that two ISPs can never
-- claim the same Provider Address, and a Customer Router walks its pool to find
-- the lowest free RFC 1918 address. Everything here is ordinary integer
-- arithmetic on a dotted quad, kept in one place so no role invents its own.

local ipv4 = {}

local OCTET = 256
local SPACE = 4294967296

-- toNumber returns the numeric form of a dotted quad, or nil when the text is
-- not a well-formed address.
function ipv4.toNumber(text)
  if type(text) ~= "string" then return nil end
  local a, b, c, d = string.match(text, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  local octets = { a, b, c, d }
  local value = 0
  for index = 1, 4 do
    local piece = octets[index]
    if #piece > 1 and string.sub(piece, 1, 1) == "0" then return nil end
    local number = tonumber(piece)
    if number > 255 then return nil end
    value = value * OCTET + number
  end
  return value
end

function ipv4.fromNumber(value)
  assert(type(value) == "number" and value == math.floor(value)
    and value >= 0 and value < SPACE, "address is outside the IPv4 space")
  local octets = {}
  for index = 4, 1, -1 do
    octets[index] = value % OCTET
    value = math.floor(value / OCTET)
  end
  return table.concat(octets, ".")
end

-- Range is an inclusive first/last pair. CraftNet always writes a range as two
-- addresses rather than as a prefix, because prefixes invite prefix routing.
function ipv4.range(first, last)
  local low = ipv4.toNumber(first)
  local high = ipv4.toNumber(last)
  if not low or not high then return nil, "a range needs two well-formed addresses" end
  if high < low then return nil, "a range must not end before it begins" end
  return { first = low, last = high }
end

function ipv4.contains(range, value)
  return value >= range.first and value <= range.last
end

function ipv4.overlaps(left, right)
  return left.first <= right.last and right.first <= left.last
end

function ipv4.size(range)
  return range.last - range.first + 1
end

-- lowestFree returns the lowest address in the range that is neither taken nor
-- reserved. A Customer Router never evicts another Computer to satisfy a new
-- request, so exhaustion is an answer rather than a reason to reuse.
function ipv4.lowestFree(range, taken, reserved)
  for value = range.first, range.last do
    local text = ipv4.fromNumber(value)
    if not (taken and taken[text]) and not (reserved and reserved[text]) then
      return text
    end
  end
  return nil
end

-- lowestFreeBlock carves the next aligned block of `size` addresses out of
-- `space` that overlaps nothing already delegated. The Central Server uses this
-- to keep every ISP's Provider Allocation disjoint.
function ipv4.lowestFreeBlock(space, size, delegated)
  assert(type(size) == "number" and size >= 1, "a block needs a positive size")
  local candidate = space.first
  while candidate + size - 1 <= space.last do
    local block = { first = candidate, last = candidate + size - 1 }
    local clear = true
    for index = 1, #delegated do
      if ipv4.overlaps(block, delegated[index]) then
        clear = false
        -- Skip past the range that blocked us rather than stepping one block at
        -- a time, so a long allocation list stays cheap to walk.
        candidate = delegated[index].last + 1
        local remainder = (candidate - space.first) % size
        if remainder ~= 0 then candidate = candidate + (size - remainder) end
        break
      end
    end
    if clear then return block end
  end
  return nil
end

-- describe renders a range the way it appears in configuration and topology.
function ipv4.describe(range)
  return { first = ipv4.fromNumber(range.first), last = ipv4.fromNumber(range.last) }
end

return ipv4
