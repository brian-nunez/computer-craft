-- The Customer Router's LAN.
--
-- Enrollment itself is the same at every parent-child boundary in CraftNet, so
-- the exchange lives in craftnet-runtime. What is genuinely a Customer Router's
-- own is here: the LAN Password is the secret, admission is rate limited
-- because a password can be guessed at online, and what gets assigned is an
-- Address Binding out of the RFC 1918 pool.
--
-- The password is never transmitted. Both sides prove they know it by signing
-- the exchange, which leaves a captured exchange open to an offline dictionary
-- attack against a weak password -- an accepted limit of a gameplay-grade
-- admission secret. What is not accepted is guessing at it online.

local internal = ...
local protocol = internal("protocol")
local runtimePackage = internal("runtime")

local lan = {}

-- The shared channel a Computer calls out on before it belongs anywhere.
lan.DISCOVERY_CHANNEL = 42002

function lan.newListener(options)
  assert(type(options) == "table", "a LAN listener needs options")
  for _, field in ipairs({ "transport", "clock", "engine", "password", "router_id" }) do
    assert(options[field] ~= nil, "a LAN listener needs '" .. field .. "'")
  end
  local engine = options.engine
  local clock = options.clock
  local listener

  listener = runtimePackage.enroll.newListener({
    transport = options.transport,
    clock = clock,
    engine = engine,
    parent_id = options.router_id,
    parent_role = "router",
    child_role = "computer",
    display_name = options.display_name or options.router_id,
    discovery_channel = options.discovery_channel or lan.DISCOVERY_CHANNEL,
    operational_channel = options.operational_channel,

    -- One LAN Password admits every Computer. Changing it affects future joins
    -- only: Computers that already joined hold their own LAN Credentials.
    candidates = function()
      return { { secret = listener.password, ref = "lan-password" } }
    end,

    -- A password can be guessed at online, so an attempt costs something before
    -- it is even considered.
    admit = function(claimed)
      local outcome = engine:handle({
        kind = "lan_admission",
        client_id = claimed.client_id,
        requested_name = claimed.requested_name,
      }, clock:now())
      if outcome.result.ok then return true end
      return false, "rate_limited"
    end,
    refused = function(claimed)
      engine:handle({
        kind = "lan_failure",
        client_id = claimed.client_id,
        requested_name = claimed.requested_name,
      }, clock:now())
    end,

    -- What a Customer Router assigns is an address out of its own pool, and an
    -- identity derived from the hostname the Operator chose. The identity does
    -- not follow a later rename: an identity is not a name.
    assign = function(request)
      local computerId = request.client_id
        or (engine.state.customer_network_id .. "-" .. request.requested_name)
      local outcome = engine:handle({
        kind = "bind_computer",
        computer_id = computerId,
        hostname = request.requested_name,
      }, clock:now())
      if not outcome.result.ok then
        return nil, outcome.result.code, outcome.result.message
      end

      local state = engine.state
      return {
        child_id = outcome.result.computer_id,
        configuration = protocol.object({
          computer_id = outcome.result.computer_id,
          hostname = outcome.result.hostname,
          address = outcome.result.address,
          customer_network_id = state.customer_network_id,
          router_address = state.router_address,
          dns_address = state.dns_address or state.router_address,
        }),
      }
    end,

    on_joined = function(joined)
      -- One mistyped password must not follow a Computer around.
      engine:handle({
        kind = "lan_success",
        client_id = joined.claimed and joined.claimed.client_id,
        requested_name = joined.claimed and joined.claimed.requested_name,
      }, clock:now())
      if options.on_joined then options.on_joined(joined) end
    end,

    credential_for = options.credential_for,
    child_of = options.child_of,
  })

  listener.password = options.password
  return listener
end

return lan
