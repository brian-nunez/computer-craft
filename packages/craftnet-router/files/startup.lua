-- The Customer Router startup program.
--
-- Loads durable state, serves the LAN, and keeps the screen current. Nothing
-- here decides anything: the engine does that, and this only turns the handle.

local directory = fs.getDir(shell.getRunningProgram())
local bootstrap = dofile(fs.combine(directory, "bootstrap.lua"))

local packages = bootstrap.packages()
local routerPackage = dofile(fs.combine(directory, "init.lua")).withPackages(packages)

local adapters = bootstrap.adapters(packages, { root = "/craftnet" })
local router = routerPackage.new({ path = "craftnet/router", adapters = adapters })

local ok, code, detail = router:start()
if not ok then
  printError("CraftNet router cannot start: " .. tostring(code) .. " " .. tostring(detail))
  printError("The snapshot could not be read. Nothing has been overwritten.")
  return
end

if not router:state().router_id then
  print("This Customer Router is not configured yet.")
  print("Run: setup")
  return
end

-- A Customer Network that has enrolled with an ISP comes back onto CraftNet.
-- One that has not simply serves its own LAN, which is a complete network in
-- its own right.
if router:state().upstream_relationship_id then
  local connected, connectCode, connectProblem = router:connectUpstream()
  if not connected then
    printError("waiting for " .. tostring(router:state().isp_id)
      .. ": " .. tostring(connectProblem or connectCode))
  end
end

router:run()
