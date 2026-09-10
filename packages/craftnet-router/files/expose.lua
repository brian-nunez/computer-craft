-- craftnet expose
--
-- Publishes one of this Customer Network's Computers to the rest of CraftNet,
-- or withdraws it again.
--
-- Nothing is reachable from another Customer Network until an Operator says so
-- here. That is the default, and it is deliberate: a Computer joining a network
-- should not quietly become an open service on it.
--
--   expose HOSTNAME SERVICE      publish it
--   expose -r HOSTNAME SERVICE   withdraw it
--   expose                       list what is published

local arguments = { ... }

local directory = fs.getDir(shell.getRunningProgram())
local bootstrap = dofile(fs.combine(directory, "bootstrap.lua"))

local packages = bootstrap.packages()
local routerPackage = dofile(fs.combine(directory, "init.lua")).withPackages(packages)

local adapters = bootstrap.adapters(packages, { root = "/craftnet" })
local router = routerPackage.new({ path = "craftnet/router", adapters = adapters })

local ok, code, detail = router:start()
if not ok then
  printError("cannot start: " .. tostring(code) .. " " .. tostring(detail))
  return
end

local state = router:state()
if not state.router_id then
  printError("Run the router wizard first: setup")
  return
end

-- computerFor turns the hostname an Operator knows into the identity the
-- router uses. Nobody should have to type a Computer identity.
local function computerFor(hostname)
  for computerId, binding in pairs(state.bindings or {}) do
    if binding.hostname == hostname or computerId == hostname then
      return computerId, binding
    end
  end
  return nil
end

local function list()
  print("CraftNet -- " .. (state.customer_network_name or state.customer_network_id))
  print()
  local found = false
  local hostnames = {}
  for computerId, services in pairs(state.exposed or {}) do
    local binding = (state.bindings or {})[computerId]
    for service, published in pairs(services) do
      if published then
        hostnames[#hostnames + 1] = (binding and binding.hostname or computerId) .. "  " .. service
        found = true
      end
    end
  end
  table.sort(hostnames)
  for _, line in ipairs(hostnames) do print("  " .. line) end
  if not found then
    print("  nothing is published")
    print()
    print("  Publish one with:  expose HOSTNAME SERVICE")
  end
end

local remove = false
local index = 1
if arguments[1] == "-r" or arguments[1] == "--remove" then
  remove = true
  index = 2
end

local hostname, service = arguments[index], arguments[index + 1]
if not hostname or not service then
  list()
  return
end

local computerId, binding = computerFor(hostname)
if not computerId then
  printError("No Computer on this network is called '" .. hostname .. "'.")
  printError("It has to join the network before it can be published.")
  return
end

local outcome = router.runtime:submit({
  kind = "expose_service",
  computer_id = computerId,
  service = service,
  exposed = not remove,
})
if not outcome.result.ok then
  printError(tostring(outcome.result.code) .. ": " .. tostring(outcome.result.message))
  return
end

if remove then
  print(service .. " on " .. hostname .. " is no longer reachable from other networks.")
else
  print(service .. " on " .. hostname .. " is now reachable as:")
  print()
  print("    " .. binding.hostname .. "." .. (state.customer_network_name or "")
    .. "." .. (state.isp_name or "") .. ".craft")
  print()
  print("Traffic to anything else on this network is still refused.")
end
