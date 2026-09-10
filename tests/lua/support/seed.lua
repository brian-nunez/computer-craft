local seed = {}
local MODULUS = 2147483647
local MULTIPLIER = 16807
local QUOTIENT = 127773
local REMAINDER = 2836

local function normalize(value)
  value = tonumber(value)
  assert(value and value == math.floor(value), "seed must be an integer")
  value = value % MODULUS
  if value <= 0 then value = value + MODULUS - 1 end
  return value
end

function seed.configured()
  return normalize(os.getenv("CRAFTNET_TEST_SEED") or 12648430)
end

function seed.new(initial)
  local state = normalize(initial)
  return {
    nextInteger = function(_, maximum)
      assert(type(maximum) == "number" and maximum >= 1 and maximum == math.floor(maximum),
        "maximum must be a positive integer")
      local high = math.floor(state / QUOTIENT)
      local low = state % QUOTIENT
      state = MULTIPLIER * low - REMAINDER * high
      if state <= 0 then state = state + MODULUS end
      return (state % maximum) + 1
    end,
    state = function() return state end,
  }
end

return seed

