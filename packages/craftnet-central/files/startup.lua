-- The Central Server startup program.

local directory = fs.getDir(shell.getRunningProgram())
local bootstrap = dofile(fs.combine(directory, "bootstrap.lua"))

local packages = bootstrap.packages()
local centralPackage = dofile(fs.combine(directory, "init.lua")).withPackages(packages)

local adapters = bootstrap.adapters(packages, { root = "/craftnet" })
local central = centralPackage.new({ path = "craftnet/central", adapters = adapters })

local ok, code, detail = central:start()
if not ok then
  printError("CraftNet Central cannot start: " .. tostring(code) .. " " .. tostring(detail))
  printError("The snapshot could not be read. Nothing has been overwritten.")
  return
end

if not central:state().world_id then
  print("This Central Server has not been provisioned yet.")
  print("Run: setup")
  return
end

central:run()
