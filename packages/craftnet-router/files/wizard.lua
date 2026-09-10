-- The Customer Router setup questions.
--
-- The questions and their validation live here, apart from the terminal that
-- asks them, so that what an Operator is allowed to type is testable without a
-- Computer. `setup.lua` is only the shell around this.

local internal = ...
local protocol = internal("protocol")
local core = internal("core")

local wizard = {}

-- The shared LAN discovery channel a Computer calls out on.
wizard.DEFAULT_DISCOVERY_CHANNEL = 42002
wizard.DEFAULT_LAN_CHANNEL = 42201
wizard.MINIMUM_PASSWORD = 8

-- questions is the order an Operator is asked. Each carries its own prompt, its
-- default, and the rule its answer has to satisfy.
wizard.questions = {
  {
    key = "customer_network_name",
    prompt = "Customer Network name",
    example = "home",
    validate = function(value)
      if not protocol.validate.normalizedName(value) then
        return nil, "a network name is 1 to 32 lowercase letters, digits, and internal hyphens"
      end
      return value
    end,
  },
  {
    key = "router_address",
    prompt = "This router's address",
    default = "192.168.1.1",
    validate = function(value)
      if not protocol.validate.customerAddress(value) then
        return nil, "an address must be inside RFC 1918 space (10.x, 172.16-31.x, or 192.168.x)"
      end
      return value
    end,
  },
  {
    key = "pool_first",
    prompt = "First address to hand out",
    default = "192.168.1.20",
    validate = function(value)
      if not protocol.validate.customerAddress(value) then
        return nil, "an address must be inside RFC 1918 space"
      end
      return value
    end,
  },
  {
    key = "pool_last",
    prompt = "Last address to hand out",
    default = "192.168.1.39",
    validate = function(value)
      if not protocol.validate.customerAddress(value) then
        return nil, "an address must be inside RFC 1918 space"
      end
      return value
    end,
  },
  {
    key = "lan_operational_channel",
    prompt = "LAN channel",
    default = tostring(wizard.DEFAULT_LAN_CHANNEL),
    validate = function(value)
      local channel = tonumber(value)
      if not protocol.validate.channel(channel) then
        return nil, "a modem channel is a whole number from 0 to 65535"
      end
      return channel
    end,
  },
  {
    key = "lan_password",
    prompt = "LAN Password",
    secret = true,
    validate = function(value)
      if type(value) ~= "string" or #value < wizard.MINIMUM_PASSWORD then
        return nil, "a LAN Password needs at least "
          .. wizard.MINIMUM_PASSWORD .. " characters; a passphrase is better than a word"
      end
      return value
    end,
  },
}

-- validate checks one answer and returns it in the form the router stores.
function wizard.validate(key, value)
  for _, question in ipairs(wizard.questions) do
    if question.key == key then return question.validate(value) end
  end
  return nil, "'" .. tostring(key) .. "' is not a setup question"
end

-- review checks the answers against each other, which is where the questions
-- that only make sense together are caught.
function wizard.review(answers)
  local range, problem = core.ipv4.range(answers.pool_first, answers.pool_last)
  if not range then
    return nil, "the address range " .. tostring(problem)
  end
  local routerValue = core.ipv4.toNumber(answers.router_address)
  if core.ipv4.contains(range, routerValue) then
    return nil, "the pool must not contain this router's own address"
  end
  if core.ipv4.size(range) < 1 then
    return nil, "the pool has to hold at least one address"
  end
  return {
    size = core.ipv4.size(range),
    first = answers.pool_first,
    last = answers.pool_last,
  }
end

-- settings turns validated answers into the configuration the engine takes.
-- Identities are derived from the network name the Operator chose, so they read
-- the same way in a snapshot as they do on a screen.
function wizard.settings(answers, context)
  context = context or {}
  local name = answers.customer_network_name
  return {
    router_id = context.router_id or ("router-" .. name),
    customer_network_id = context.customer_network_id or ("network-" .. name),
    customer_network_name = name,
    router_address = answers.router_address,
    dns_address = answers.router_address,
    pool_first = answers.pool_first,
    pool_last = answers.pool_last,
    lan_operational_channel = answers.lan_operational_channel,
    isp_id = context.isp_id,
    isp_name = context.isp_name,
    provider_address = context.provider_address,
    world_id = context.world_id,
  }
end

return wizard
