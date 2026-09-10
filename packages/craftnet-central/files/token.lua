-- craftnet token
--
-- Issues a one-time ISP Enrollment Token. Carry it to the ISP's Computer and
-- type it into that wizard. A token is spent the moment an ISP finishes
-- enrolling with it, and running this again issues a new one.

local directory = fs.getDir(shell.getRunningProgram())
local bootstrap = dofile(fs.combine(directory, "bootstrap.lua"))

local packages = bootstrap.packages()
local centralPackage = dofile(fs.combine(directory, "init.lua")).withPackages(packages)

local adapters = bootstrap.adapters(packages, { root = "/craftnet" })
local central = centralPackage.new({ path = "craftnet/central", adapters = adapters })

local ok, code, detail = central:start()
if not ok then
  printError("cannot start: " .. tostring(code) .. " " .. tostring(detail))
  return
end

local token, counter, problem = central:issueToken()
if not token then
  printError(tostring(counter) .. ": " .. tostring(problem))
  return
end

print("ISP Enrollment Token #" .. counter)
print()
print("    " .. token)
print()
print("It is spent once an ISP enrolls with it.")
