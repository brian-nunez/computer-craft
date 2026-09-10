local tests = {}
local failures = 0

function _G.test(name, body)
  assert(type(name) == "string" and name ~= "", "test name must be a non-empty string")
  assert(type(body) == "function", "test body must be a function")
  tests[#tests + 1] = { name = name, body = body }
end

function _G.assertEqual(actual, expected, message)
  if actual ~= expected then
    error((message and (message .. ": ") or "")
      .. "expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

function _G.assertTrue(value, message)
  if not value then error(message or "expected a truthy value", 2) end
end

if #arg == 0 then
  io.stderr:write("usage: lua tests/lua/test_runner.lua <test-file>...\n")
  os.exit(2)
end

for _, path in ipairs(arg) do
  local chunk, loadError = loadfile(path)
  if not chunk then
    io.stderr:write("not ok - load " .. path .. ": " .. tostring(loadError) .. "\n")
    os.exit(1)
  end
  local ok, runError = xpcall(chunk, debug.traceback)
  if not ok then
    io.stderr:write("not ok - load " .. path .. ": " .. tostring(runError) .. "\n")
    os.exit(1)
  end
end

for _, case in ipairs(tests) do
  local ok, message = xpcall(case.body, debug.traceback)
  if ok then
    print("ok - " .. case.name)
  else
    failures = failures + 1
    io.stderr:write("not ok - " .. case.name .. "\n" .. tostring(message) .. "\n")
  end
end

print(string.format("%d tests, %d failures", #tests, failures))
if failures > 0 then os.exit(1) end

