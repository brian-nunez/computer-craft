local tempState = {}
local counter = 0

local function root()
  local value = os.getenv("CRAFTNET_TEST_TMPDIR")
  assert(value and value ~= "", "CRAFTNET_TEST_TMPDIR must be set by the test entry point")
  return value
end

function tempState.path(name)
  assert(type(name) == "string" and name:match("^[a-zA-Z0-9_.-]+$"), "unsafe temporary state name")
  counter = counter + 1
  return root() .. "/" .. tostring(counter) .. "-" .. name
end

function tempState.write(name, contents)
  local path = tempState.path(name)
  local handle = assert(io.open(path, "wb"))
  assert(handle:write(contents))
  assert(handle:close())
  return path
end

function tempState.read(path)
  local handle = assert(io.open(path, "rb"))
  local contents = assert(handle:read("*a"))
  assert(handle:close())
  return contents
end

return tempState

