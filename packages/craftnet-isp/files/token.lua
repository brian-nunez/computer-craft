-- craftnet token
--
-- Issues a one-time Router Enrollment Token. Carry it to the Customer Router's
-- Computer and type it into that wizard.

local directory = fs.getDir(shell.getRunningProgram())
local bootstrap = dofile(fs.combine(directory, "bootstrap.lua"))

local packages = bootstrap.packages()
local ispPackage = dofile(fs.combine(directory, "init.lua")).withPackages(packages)

local adapters = bootstrap.adapters(packages, { root = "/craftnet" })
local node = ispPackage.new({ path = "craftnet/isp", adapters = adapters })

local ok, code, detail = node:start()
if not ok then
  printError("cannot start: " .. tostring(code) .. " " .. tostring(detail))
  return
end

local token, counter, problem = node:issueToken()
if not token then
  printError(tostring(counter) .. ": " .. tostring(problem))
  return
end

print("Router Enrollment Token #" .. counter)
print()
print("    " .. token)
print()
print("It is spent once a Customer Router enrolls with it.")
