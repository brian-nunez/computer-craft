-- craftnet uplink
--
-- Puts this Customer Network on CraftNet by spending a one-time Router
-- Enrollment Token. A Customer Network works without this -- it just cannot be
-- reached from another one.

local directory = fs.getDir(shell.getRunningProgram())
local bootstrap = dofile(fs.combine(directory, "bootstrap.lua"))

local packages = bootstrap.packages()
local routerPackage = dofile(fs.combine(directory, "init.lua")).withPackages(packages)
local protocol = packages.protocol

local adapters = bootstrap.adapters(packages, { root = "/craftnet" })
local router = routerPackage.new({ path = "craftnet/router", adapters = adapters })

local ok, code, detail = router:start()
if not ok then
  printError("cannot start: " .. tostring(code) .. " " .. tostring(detail))
  return
end

if not router:state().router_id then
  printError("Run the router wizard first: setup")
  return
end

print("CraftNet -- connect to an ISP")
print()

local token
while true do
  write("Router Enrollment Token: ")
  token = protocol.tokens.normalize(read())
  if token then break end
  printError("  a token is " .. protocol.tokens.LENGTH
    .. " characters, usually written in groups of four")
end

print()
print("Looking for an ISP...")

local enrolled, enrollCode, enrollProblem =
  router:enrollUpstream({ token = token, timeout_ms = 10000 })
if not enrolled then
  printError(tostring(enrollCode) .. ": " .. tostring(enrollProblem))
  if enrollCode == "name_conflict" then
    printError("That ISP already serves a different Customer Network by this name.")
  end
  return
end

print()
print("Connected to " .. tostring(enrolled.isp_id))
print("  provider address  " .. tostring(enrolled.provider_address))
print("  channel           " .. tostring(enrolled.operational_channel))
