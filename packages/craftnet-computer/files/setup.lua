-- craftnet join
--
-- Joins this Computer to a Customer Network. It needs the LAN Password once and
-- never stores it: what is kept is the LAN Credential the join produces, which
-- is unique to this Computer and can be revoked on its own.

local directory = fs.getDir(shell.getRunningProgram())
local bootstrap = dofile(fs.combine(directory, "bootstrap.lua"))

local packages = bootstrap.packages()
local computerPackage = dofile(fs.combine(directory, "init.lua")).withPackages(packages)
local protocol = packages.protocol

local function askHostname()
  local suggested = "computer-" .. os.getComputerID()
  while true do
    write("Hostname [" .. suggested .. "]: ")
    local answer = read()
    if answer == "" then answer = suggested end
    if protocol.validate.normalizedName(answer) then return answer end
    printError("  a hostname is 1 to 32 lowercase letters, digits, and internal hyphens")
  end
end

print("CraftNet -- join a Customer Network")
print()

local hostname = askHostname()
write("LAN Password: ")
local password = read("*")

local adapters = bootstrap.adapters(packages, { root = "/craftnet" })
local node = computerPackage.new({
  path = "craftnet/computer",
  computer_number = os.getComputerID(),
  adapters = adapters,
})

local ok, code, detail = node:start()
if not ok then
  printError("cannot start: " .. tostring(code) .. " " .. tostring(detail))
  return
end

print()
print("Looking for a Customer Router...")

local joined, joinCode, joinProblem = node:joinNetwork({
  password = password,
  hostname = hostname,
  timeout_ms = 10000,
})
if not joined then
  printError(tostring(joinCode) .. ": " .. tostring(joinProblem))
  if joinCode == "authentication_failed" then
    printError("The LAN Password was refused.")
  elseif joinCode == "router_unavailable" then
    printError("No Customer Router answered. Check the modem and the router.")
  end
  return
end

print()
print("Joined " .. tostring(joined.hostname))
print("  address  " .. joined.address)
print("  router   " .. joined.router_address)
print("  dns      " .. joined.dns_address)
print()
print("Start with: startup")
