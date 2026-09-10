-- craftnet revoke
--
-- Takes one Computer off this Customer Network.
--
-- Its LAN Credential is destroyed and its Address Binding is released, so the
-- address goes back to the pool for the next Computer to take. Every other
-- Computer is untouched: revoking one credential is not an outage.
--
-- A Computer that has been revoked can join again with the LAN Password, and
-- gets a new credential and whatever address is lowest and free at the time.
--
--   revoke HOSTNAME
--   revoke               list what is on this network

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

local function list()
  print("CraftNet -- " .. (state.customer_network_name or state.customer_network_id))
  print()
  local lines = {}
  for computerId, binding in pairs(state.bindings or {}) do
    lines[#lines + 1] = string.format("  %-16s %s", binding.hostname or computerId, binding.address)
  end
  table.sort(lines)
  if #lines == 0 then
    print("  no Computers have joined")
  else
    for _, line in ipairs(lines) do print(line) end
  end
end

local hostname = arguments[1]
if not hostname then
  list()
  return
end

local computerId, binding
for identity, held in pairs(state.bindings or {}) do
  if held.hostname == hostname or identity == hostname then
    computerId, binding = identity, held
  end
end
if not computerId then
  printError("No Computer on this network is called '" .. hostname .. "'.")
  return
end

local relationshipId
for identity, childId in pairs(state.relationships or {}) do
  if childId == computerId then relationshipId = identity end
end

print("Revoking " .. hostname .. " (" .. binding.address .. ").")
print()
print("Its credential is destroyed and its address returns to the pool.")
print("It can rejoin with the LAN Password, and may get a different address.")
write("Revoke it? [y/N]: ")
if read():lower() ~= "y" then
  print("Nothing was changed.")
  return
end

if relationshipId then
  router:revoke(relationshipId)
else
  -- It has a binding but no live relationship, which is what a Computer that
  -- was destroyed in world looks like. Releasing the binding is the whole job.
  local outcome = router.runtime:submit({ kind = "release_binding", computer_id = computerId })
  if not outcome.result.ok then
    printError(tostring(outcome.result.code) .. ": " .. tostring(outcome.result.message))
    return
  end
end

print()
print(hostname .. " is off this network and " .. binding.address .. " is free again.")
