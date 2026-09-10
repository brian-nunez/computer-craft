-- craftnet setup router
--
-- The Customer Router wizard. It asks the questions in wizard.lua, checks each
-- answer as it is given rather than at the end, and writes the result once.
-- Run it again to change the LAN Password; the network keeps its identity and
-- every Computer keeps its address.

local directory = fs.getDir(shell.getRunningProgram())
local bootstrap = dofile(fs.combine(directory, "bootstrap.lua"))

local packages = bootstrap.packages()
local routerPackage = dofile(fs.combine(directory, "init.lua")).withPackages(packages)
local wizard = routerPackage.wizard

local function ask(question)
  while true do
    local suffix = question.default and (" [" .. question.default .. "]") or ""
    if question.example then suffix = suffix .. " (e.g. " .. question.example .. ")" end
    write(question.prompt .. suffix .. ": ")
    local answer = question.secret and read("*") or read()
    if answer == "" and question.default then answer = question.default end

    local value, problem = question.validate(answer)
    if value ~= nil then return value end
    printError("  " .. problem)
  end
end

print("CraftNet -- Customer Router setup")
print()

local answers = {}
for _, question in ipairs(wizard.questions) do
  answers[question.key] = ask(question)
end

local review, problem = wizard.review(answers)
if not review then
  printError(problem)
  return
end

print()
print("Network:  " .. answers.customer_network_name)
print("Router:   " .. answers.router_address)
print("Pool:     " .. review.first .. " - " .. review.last
  .. "  (" .. review.size .. " Computers)")
print("Channel:  " .. answers.lan_operational_channel)
write("Write this configuration? [y/N]: ")
if read():lower() ~= "y" then
  print("Nothing was changed.")
  return
end

local adapters = bootstrap.adapters(packages, { root = "/craftnet" })
local router = routerPackage.new({ path = "craftnet/router", adapters = adapters })

local ok, code, detail = router:start()
if not ok then
  printError("cannot start: " .. tostring(code) .. " " .. tostring(detail))
  return
end

local applied, applyCode, applyProblem =
  router:configure(wizard.settings(answers), answers.lan_password)
if not applied then
  printError(tostring(applyCode) .. ": " .. tostring(applyProblem))
  return
end

print()
print("Done. Computers join with:  setup")
print("Start the router with:      startup")
