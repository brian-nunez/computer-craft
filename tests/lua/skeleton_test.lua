local seed = require("tests.lua.support.seed")
local tempState = require("tests.lua.support.temp_state")

test("deterministic seed repeats its sequence", function()
  local left = seed.new(42)
  local right = seed.new(42)
  for _ = 1, 8 do
    assertEqual(left:nextInteger(100000), right:nextInteger(100000))
  end
end)

test("temporary state is isolated outside the repository", function()
  local path = tempState.write("smoke.txt", "craftnet")
  assertEqual(tempState.read(path), "craftnet")
  assertTrue(path:find(os.getenv("CRAFTNET_TEST_TMPDIR"), 1, true) == 1)
end)

test("package skeletons expose version metadata", function()
  for _, name in ipairs({ "craftnet-protocol", "craftnet-core", "craftnet-runtime" }) do
    local package = dofile("packages/" .. name .. "/files/init.lua")
    assertEqual(package.name, name)
    assertEqual(package.version, "0.1.0")
    assertEqual(package.wireVersion, 1)
  end
end)

