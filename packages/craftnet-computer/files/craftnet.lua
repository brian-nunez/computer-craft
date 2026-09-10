-- craftnet
--
-- The Computer's own command line. Everything an Operator needs to check that
-- this Computer is really on CraftNet, and to use it once it is.
--
--   craftnet status              what this Computer is and where
--   craftnet resolve NAME        turn a CraftNet Name into a scoped address
--   craftnet call NAME SERVICE   call a service and print what comes back
--
-- A short name resolves inside this Computer's own Customer Network; a longer
-- one widens a label at a time, up to the fully qualified `.craft` form.
--
-- api.craft is the External Application, and it is the one name that is not a
-- Computer: `craftnet call api.craft test.identity` registers this device if it
-- has never registered, holds an Access Token until it is nearly spent, and
-- makes the call.

local arguments = { ... }

local directory = fs.getDir(shell.getRunningProgram())
local bootstrap = dofile(fs.combine(directory, "bootstrap.lua"))

local packages = bootstrap.packages()
local computerPackage = dofile(fs.combine(directory, "init.lua")).withPackages(packages)
local protocol = packages.protocol

local adapters = bootstrap.adapters(packages, { root = "/craftnet" })
local computer = computerPackage.new({ path = "craftnet/computer", adapters = adapters })

local ok, code, detail = computer:start()
if not ok then
  printError("cannot start: " .. tostring(code) .. " " .. tostring(detail))
  return
end
if not computer:isJoined() then
  printError("This Computer has not joined a Customer Network yet.")
  printError("Run: setup")
  return
end

local function usage()
  print("CraftNet")
  print()
  print("  craftnet status")
  print("  craftnet resolve NAME")
  print("  craftnet call NAME SERVICE")
  print("  craftnet call api.craft OPERATION")
end

--------------------------------------------------------------------------
-- status
--------------------------------------------------------------------------

local function status()
  local state = computer:state()
  print("CraftNet -- " .. tostring(state.hostname))
  print()
  print("  Address    " .. tostring(state.address))
  print("  Network    " .. tostring(state.customer_network_name)
    .. " (" .. tostring(state.customer_network_id) .. ")")
  print("  Router     " .. tostring(state.router_address))
  print("  DNS        " .. tostring(state.dns_address))
  print("  ISP        " .. tostring(state.isp_name))
  print("  World      " .. tostring(state.world_id))
  print()
  print("  Full name  " .. tostring(state.hostname) .. "." ..
    tostring(state.customer_network_name) .. "." .. tostring(state.isp_name) .. ".craft")
end

--------------------------------------------------------------------------
-- Waiting for an answer
--------------------------------------------------------------------------

-- await serves this Computer until the thing it just asked for comes back. A
-- CraftNet call is one request and one answer; there is nothing to poll.
local function await(what)
  for _ = 1, 60 do
    local outcome = computer:serve(200)
    if outcome and outcome.result then
      local result = outcome.result
      if result.ok == false then return nil, result.code, result.message end
      if result.payload ~= nil or result.address ~= nil or result.canonical_name ~= nil then
        return result
      end
    end
  end
  return nil, "request_timeout", what .. " was never answered"
end

local function connect()
  local established, problem, message = computer:connect()
  if not established then
    printError("This Computer cannot reach its router: "
      .. tostring(problem) .. " " .. tostring(message))
    printError("Is the router running? Start it there with: startup")
    return false
  end
  return true
end

--------------------------------------------------------------------------
-- resolve
--------------------------------------------------------------------------

local function resolve(name)
  if not name then
    printError("Which name? For example: craftnet resolve harvester.farm.acme.craft")
    return
  end
  if not connect() then return end

  local outcome = computer:resolve(name)
  if not outcome.result.ok then
    printError(tostring(outcome.result.code) .. ": " .. tostring(outcome.result.message))
    return
  end
  if outcome.result.address then
    -- api.craft and anything else answered without a lookup.
    print(name .. "  ->  " .. tostring(outcome.result.address))
    return outcome.result
  end

  local answer, problem, message = await("that lookup")
  if not answer then
    printError(tostring(problem) .. ": " .. tostring(message))
    return
  end
  print(tostring(answer.canonical_name or name))
  print("  network   " .. tostring(answer.customer_network_id))
  print("  computer  " .. tostring(answer.computer_id))
  print("  address   " .. tostring(answer.address))
  return answer
end

--------------------------------------------------------------------------
-- call
--------------------------------------------------------------------------

-- show prints whatever an answer carried, in a stable order.
local function show(heading, payload)
  print(heading)
  payload = payload or protocol.object()
  local keys = {}
  for key in pairs(payload) do keys[#keys + 1] = key end
  table.sort(keys)
  if #keys == 0 then
    print("  (it answered with nothing)")
  end
  for _, key in ipairs(keys) do
    print("  " .. key .. " = " .. tostring(rawget(payload, key)))
  end
end

-- external calls the External Application. There is no address to look up:
-- api.craft is reached through an External Operation and the ancestry every hop
-- between here and the Central Server derived, never by routing to it.
--
-- Registering and getting a token happen underneath. An Operator types the
-- operation they want, not the three calls it takes the first time.
--
-- It is reached through `call`, which has already connected to the router.
local function external(operation)
  if not operation then
    printError("Which operation? For example: craftnet call api.craft test.identity")
    return
  end

  local payload, code, problem = computer:call(operation, protocol.object())
  if not payload then
    printError(tostring(code) .. ": " .. tostring(problem))
    if code == "gateway_unavailable" then
      printError("The External Application is not reachable. Everything in world still works.")
    end
    return
  end
  show(operation .. " on api.craft", payload)
  return payload
end

local function call(name, service)
  if not name or not service then
    printError("Which name and which service?")
    printError("For example: craftnet call harvester.farm.acme.craft harvester.status")
    return
  end
  if not connect() then return end

  local outcome = computer:resolve(name)
  if not outcome.result.ok then
    printError(tostring(outcome.result.code) .. ": " .. tostring(outcome.result.message))
    return
  end
  local target = outcome.result
  if target.kind == "external" then
    return external(service)
  end
  if not target.computer_id then
    local answer, problem, message = await("that lookup")
    if not answer then
      printError(tostring(problem) .. ": " .. tostring(message))
      return
    end
    target = answer
  end

  local sent = computer:request({
    customer_network_id = target.customer_network_id,
    computer_id = target.computer_id,
  }, service, protocol.object())
  if not sent.result.ok then
    printError(tostring(sent.result.code) .. ": " .. tostring(sent.result.message))
    return
  end

  local answer, problem, message = await("that call")
  if not answer then
    printError(tostring(problem) .. ": " .. tostring(message))
    return
  end

  show(service .. " on " .. name, answer.payload)
end

--------------------------------------------------------------------------

local command = arguments[1]
if command == "status" or command == nil then
  status()
elseif command == "resolve" then
  resolve(arguments[2])
elseif command == "call" then
  call(arguments[2], arguments[3])
else
  usage()
end
