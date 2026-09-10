-- Joining a Customer Network.
--
-- A Computer finds a router, proves it knows the LAN Password without ever
-- sending it, and comes away with three durable things: its identity, its
-- configuration, and the LAN Credential it will authenticate with from then on.
--
-- The exchange itself is the one every CraftNet child runs, so it lives in
-- craftnet-runtime. This says only what makes it a LAN join: the secret is a
-- password, and the child is a Computer.

local internal = ...
local runtimePackage = internal("runtime")

local join = {}

join.DISCOVERY_CHANNEL = 42002

-- run performs the whole join. The password is used exactly once.
function join.run(options)
  assert(type(options) == "table", "a join needs options")
  return runtimePackage.enroll.child({
    transport = options.transport,
    clock = options.clock,
    discovery_channel = options.discovery_channel or join.DISCOVERY_CHANNEL,
    secret = options.password,
    role = "computer",
    requested_name = options.requested_name,
    client_id = options.client_id,
    number = options.computer_number,
    generation = options.generation,
    child_revision = options.child_revision,
    timeout_ms = options.timeout_ms,
    -- When the Operator named the network, an offer from a neighbouring
    -- Customer Network in range is ignored rather than accepted.
    expect_display_name = options.customer_network_name,
    expect_parent_id = options.router_id,
  })
end

-- reconnect establishes a fresh Authenticated Session with the credential the
-- join produced. It never uses the LAN Password again, and it only ever talks
-- to the router identity this Computer joined.
function join.reconnect(options)
  assert(type(options) == "table", "a reconnect needs options")
  return runtimePackage.enroll.session({
    transport = options.transport,
    clock = options.clock,
    credential = options.credential,
    relationship_id = options.relationship_id,
    operational_channel = options.operational_channel,
    role = "computer",
    generation = options.generation,
    child_revision = options.child_revision,
    timeout_ms = options.timeout_ms,
  })
end

return join
