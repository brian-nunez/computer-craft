-- craftnet setup isp
--
-- Names this ISP and spends a one-time ISP Enrollment Token to take a place in
-- the World. What comes back is an identity, a Provider Allocation, and an
-- Operational Channel -- all of them the Central Server's to decide.

local directory = fs.getDir(shell.getRunningProgram())
local bootstrap = dofile(fs.combine(directory, "bootstrap.lua"))

local packages = bootstrap.packages()
local ispPackage = dofile(fs.combine(directory, "init.lua")).withPackages(packages)
local wizard = ispPackage.wizard

local function ask(question)
  while true do
    local suffix = question.example and (" (e.g. " .. question.example .. ")") or ""
    write(question.prompt .. suffix .. ": ")
    local value, problem = question.validate(read())
    if value ~= nil then return value end
    printError("  " .. problem)
  end
end

print("CraftNet -- ISP setup")
print()

local answers = {}
for _, question in ipairs(wizard.questions) do
  answers[question.key] = ask(question)
end

local adapters = bootstrap.adapters(packages, { root = "/craftnet" })
local node = ispPackage.new({ path = "craftnet/isp", adapters = adapters })

local ok, code, detail = node:start()
if not ok then
  printError("cannot start: " .. tostring(code) .. " " .. tostring(detail))
  return
end

local configured, configureCode, configureProblem =
  node:configure(wizard.settings(answers))
if not configured then
  printError(tostring(configureCode) .. ": " .. tostring(configureProblem))
  return
end

print()
print("Looking for a Central Server...")

local enrolled, enrollCode, enrollProblem =
  node:enrollUpstream({ token = answers.token, timeout_ms = 10000 })
if not enrolled then
  printError(tostring(enrollCode) .. ": " .. tostring(enrollProblem))
  if enrollCode == "authentication_failed" then
    printError("The token was refused. It may already have been spent.")
  elseif enrollCode == "upstream_unavailable" then
    printError("No Central Server answered. Check the Ender modem.")
  end
  return
end

print()
print("Enrolled as " .. enrolled.isp_id)
print("  allocation  " .. enrolled.provider_allocations[1].first
  .. " - " .. enrolled.provider_allocations[1].last)
print("  address     " .. tostring(enrolled.provider_address))
print("  channel     " .. tostring(enrolled.operational_channel))
print()
print("Issue a Router Enrollment Token with: token")
print("Start the ISP with:                   startup")
