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

router:run()
