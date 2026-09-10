-- The programs an Operator actually types.
--
-- Milestone 8's gate says a second Operator must be able to follow the
-- documentation without editing source. That only holds if every command the
-- documentation names exists, loads, and reaches for nothing CC:Tweaked does
-- not provide.
--
-- What this cannot do is drive an interactive wizard: `read` is a person. Those
-- paths are on the in-world checklist, and this covers everything up to them.

local PROGRAMS = {
  ["craftnet-central"] = { "setup", "token", "startup" },
  ["craftnet-isp"] = { "setup", "token", "startup" },
  ["craftnet-router"] = { "setup", "uplink", "startup", "expose", "revoke" },
  ["craftnet-computer"] = { "setup", "startup", "craftnet" },
}

-- Everything CC:Tweaked puts in a program's environment, plus the Lua standard
-- library. A name outside this list is a program reaching for something that
-- will not be there when a player runs it.
local AVAILABLE = {}
for _, name in ipairs({
  -- CraftOS
  "fs", "shell", "term", "textutils", "peripheral", "http", "os", "io",
  "colors", "colours", "keys", "paintutils", "parallel", "settings", "vector",
  "window", "redstone", "rednet", "disk", "multishell", "gps", "read", "write",
  "print", "printError", "sleep", "loadfile", "dofile", "require",
  -- Lua
  "assert", "error", "pairs", "ipairs", "next", "select", "type", "tostring",
  "tonumber", "setmetatable", "getmetatable", "rawget", "rawset", "rawequal",
  "rawlen", "pcall", "xpcall", "unpack", "string", "table", "math", "coroutine",
  "bit32", "utf8", "_G", "_VERSION", "collectgarbage", "load", "loadstring",
  "tostring", "arg",
}) do AVAILABLE[name] = true end

-- stripped removes comments and string literals, so a scan for a name sees code
-- rather than prose. Without this, the word "across" in a comment reads as a
-- function call.
local function stripped(source)
  source = string.gsub(source, "%-%-%[%[.-%]%]", " ")
  source = string.gsub(source, "%-%-[^\n]*", " ")
  source = string.gsub(source, '"[^"\n]*"', '""')
  source = string.gsub(source, "'[^'\n]*'", "''")
  source = string.gsub(source, "%[%[.-%]%]", "[[]]")
  return source
end

local function lines(source)
  local found = {}
  for line in string.gmatch(source .. "\n", "([^\n]*)\n") do found[#found + 1] = line end
  return found
end

local function sourceOf(package, program)
  local path = "packages/" .. package .. "/files/" .. program .. ".lua"
  local handle = assert(io.open(path, "r"), "missing program: " .. path)
  local source = handle:read("*a")
  handle:close()
  return source, path
end

--------------------------------------------------------------------------

test("every program the documentation names exists and compiles", function()
  local counted = 0
  for package, programs in pairs(PROGRAMS) do
    for _, program in ipairs(programs) do
      local source, path = sourceOf(package, program)
      local chunk, problem = load(source, "@" .. path)
      assertTrue(chunk ~= nil, path .. " does not compile: " .. tostring(problem))
      counted = counted + 1
    end
  end
  assertTrue(counted >= 14, "the documented command set is " .. counted .. " programs")
end)

test("no program reaches for a global CC:Tweaked does not provide", function()
  for package, programs in pairs(PROGRAMS) do
    for _, program in ipairs(programs) do
      local source, path = sourceOf(package, program)

      -- A CC:Tweaked program runs with one environment and no module system,
      -- so every name it calls has to be one CraftOS put there, or one it
      -- declared itself.
      local code = stripped(source)
      local declared = {}
      for name in string.gmatch(code, "local%s+([%a_][%w_]*)") do declared[name] = true end
      for name in string.gmatch(code, "local%s+function%s+([%a_][%w_]*)") do declared[name] = true end
      for group in string.gmatch(code, "local%s+([%a_][%w_,%s]*)=") do
        for name in string.gmatch(group, "([%a_][%w_]*)") do declared[name] = true end
      end
      for name in string.gmatch(code, "function%s+([%a_][%w_]*)%s*%(") do declared[name] = true end

      for prefix, name in string.gmatch(code, "([%w_%.%:]?)([%a_][%w_]*)%s*[%(%.%[]") do
        if prefix == "" then
          assertTrue(AVAILABLE[name] or declared[name],
            path .. " reaches for '" .. name .. "'")
        end
      end
    end
  end
end)

test("every program says what to do when it cannot start", function()
  for package, programs in pairs(PROGRAMS) do
    for _, program in ipairs(programs) do
      local source, path = sourceOf(package, program)
      -- A program that can fail has to say so in words a player can act on,
      -- rather than leaving a stack trace on a Computer with no console.
      if string.find(source, ":start%(%)", 1) then
        assertTrue(string.find(source, "printError", 1, true) ~= nil,
          path .. " can fail to start but never says so")
      end
    end
  end
end)

test("no program prints a secret it was given", function()
  for package, programs in pairs(PROGRAMS) do
    for _, program in ipairs(programs) do
      local source, path = sourceOf(package, program)
      -- A password is read and used; it is never echoed, and never printed
      -- back for confirmation.
      for number, line in ipairs(lines(stripped(source))) do
        if string.find(line, "print") then
          assertTrue(string.find(line, "password") == nil,
            path .. ":" .. number .. " prints a password")
          assertTrue(string.find(line, "credential") == nil,
            path .. ":" .. number .. " prints a credential")
        end
      end
      -- And a password typed at a prompt is masked as it is typed. A program
      -- that only mentions one in its output is not prompting for anything.
      local held = lines(source)
      for number, line in ipairs(held) do
        if string.find(line, "write%(") and string.find(line, "[Pp]assword") then
          local masked = false
          for ahead = number, math.min(number + 3, #held) do
            if string.find(held[ahead], 'read("*")', 1, true)
              or string.find(held[ahead], "secret", 1, true) then
              masked = true
            end
          end
          assertTrue(masked, path .. ":" .. number .. " prompts for a password unmasked")
        end
      end
    end
  end
end)
