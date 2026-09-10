-- The Computer startup program.
--
-- Reconnects with the LAN Credential this Computer already holds, and only to
-- the router identity it originally joined. It never uses the LAN Password
-- again, and it never joins another network that happens to share a name.

local directory = fs.getDir(shell.getRunningProgram())
local bootstrap = dofile(fs.combine(directory, "bootstrap.lua"))

local packages = bootstrap.packages()
local computerPackage = dofile(fs.combine(directory, "init.lua")).withPackages(packages)

local adapters = bootstrap.adapters(packages, { root = "/craftnet" })
local node = computerPackage.new({
  path = "craftnet/computer",
  computer_number = os.getComputerID(),
  adapters = adapters,
})

local ok, code, detail = node:start()
if not ok then
  printError("CraftNet cannot start: " .. tostring(code) .. " " .. tostring(detail))
  return
end

if not node:isJoined() then
  print("This Computer has not joined a Customer Network.")
  print("Run: setup")
  return
end

local connected, connectCode, connectProblem = node:connect()
if not connected then
  -- Not fatal: the runtime keeps the cached configuration on screen and retries
  -- under backoff until the router is back.
  printError("waiting for " .. tostring(node:state().router_id)
    .. ": " .. tostring(connectProblem or connectCode))
end

node:run()
