-- The ISP startup program.

local directory = fs.getDir(shell.getRunningProgram())
local bootstrap = dofile(fs.combine(directory, "bootstrap.lua"))

local packages = bootstrap.packages()
local ispPackage = dofile(fs.combine(directory, "init.lua")).withPackages(packages)

local adapters = bootstrap.adapters(packages, { root = "/craftnet" })
local node = ispPackage.new({ path = "craftnet/isp", adapters = adapters })

local ok, code, detail = node:start()
if not ok then
  printError("CraftNet ISP cannot start: " .. tostring(code) .. " " .. tostring(detail))
  return
end

if not node:state().isp_id then
  print("This ISP has not been set up yet.")
  print("Run: setup")
  return
end

local connected, connectCode, connectProblem = node:connectUpstream()
if not connected then
  printError("waiting for " .. tostring(node:state().central_id)
    .. ": " .. tostring(connectProblem or connectCode))
end

node:run()
