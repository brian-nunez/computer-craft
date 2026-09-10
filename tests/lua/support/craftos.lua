-- Just enough CraftOS to run ccpm.
--
-- ccpm is the program that actually puts CraftNet on a Computer, so it deserves
-- to be tested rather than trusted. This supplies the four globals it uses --
-- a filesystem in a table, an http that serves this repository from disk, JSON,
-- and printing -- and nothing else. A reference ccpm has not declared will fail
-- loudly rather than silently reach the real world.

local craftos = {}

local Host = {}
Host.__index = Host

--------------------------------------------------------------------------
-- Filesystem
--------------------------------------------------------------------------

local function normalize(path)
  path = tostring(path)
  if path:sub(1, 1) ~= "/" then path = "/" .. path end
  path = path:gsub("//+", "/")
  if #path > 1 and path:sub(-1) == "/" then path = path:sub(1, -2) end
  return path
end

local function newFilesystem()
  local files = {}
  local directories = { ["/"] = true }

  local fs = { files = files, directories = directories }

  function fs.exists(path)
    path = normalize(path)
    return files[path] ~= nil or directories[path] == true
  end

  function fs.isDir(path)
    return directories[normalize(path)] == true
  end

  function fs.getDir(path)
    path = normalize(path)
    local parent = path:match("^(.*)/[^/]*$")
    if parent == nil or parent == "" then return "" end
    return parent:sub(2)
  end

  function fs.combine(left, right)
    return normalize(normalize(left) .. "/" .. tostring(right)):sub(2)
  end

  function fs.makeDir(path)
    path = normalize(path)
    local walked = ""
    for segment in path:gmatch("[^/]+") do
      walked = walked .. "/" .. segment
      directories[walked] = true
    end
    return true
  end

  function fs.delete(path)
    path = normalize(path)
    files[path] = nil
    directories[path] = nil
    return true
  end

  function fs.move(from, to)
    from, to = normalize(from), normalize(to)
    assert(files[from], "cannot move a file that does not exist: " .. from)
    files[to] = files[from]
    files[from] = nil
    return true
  end

  function fs.open(path, mode)
    path = normalize(path)
    if mode == "r" then
      local contents = files[path]
      if not contents then return nil end
      return {
        readAll = function() return contents end,
        close = function() return true end,
      }
    end
    if mode == "w" then
      local buffer = {}
      return {
        write = function(text) buffer[#buffer + 1] = tostring(text) end,
        close = function()
          files[path] = table.concat(buffer)
          return true
        end,
      }
    end
    error("unsupported file mode: " .. tostring(mode), 0)
  end

  return fs
end

--------------------------------------------------------------------------
-- JSON
--------------------------------------------------------------------------

-- CC:Tweaked's textutils speaks JSON. The repository's own protocol package
-- already has a strict encoder and decoder, so this borrows them rather than
-- carrying a third implementation.
local function newTextutils()
  local protocol = dofile("packages/craftnet-protocol/files/init.lua")
  local cj1 = protocol.conformance.cj1

  local function toPlain(value)
    if type(value) ~= "table" then return value end
    if value == cj1.null then return nil end
    local result = {}
    for key, entry in pairs(value) do
      local converted = toPlain(entry)
      if converted ~= nil then result[key] = converted end
    end
    return result
  end

  return {
    unserialiseJSON = function(body)
      local value = cj1.decode(body)
      if not value then return nil, "invalid JSON" end
      return toPlain(value)
    end,
    serialiseJSON = function(value)
      local function toWire(entry)
        if type(entry) ~= "table" then return entry end
        local isArray = #entry > 0
        local hasStringKey = false
        for key in pairs(entry) do
          if type(key) == "string" then hasStringKey = true end
        end
        if isArray and not hasStringKey then
          local list = protocol.array()
          for index = 1, #entry do rawset(list, index, toWire(entry[index])) end
          return list
        end
        local object = protocol.object()
        for key, item in pairs(entry) do rawset(object, tostring(key), toWire(item)) end
        return object
      end
      return (assert(cj1.encode(toWire(value))))
    end,
  }
end

--------------------------------------------------------------------------
-- http
--------------------------------------------------------------------------

-- newHttp serves this repository from disk under the URL prefix the manifests
-- publish, so ccpm resolves against exactly the files that would be pushed.
local function newHttp(prefix, root)
  local http = {}

  function http.serve(url)
    local relative = url:sub(#prefix + 1)
    assert(relative ~= url, "the fake http only serves " .. prefix .. " (asked for " .. url .. ")")
    assert(not relative:find("%.%."), "unsafe path in " .. url)
    local handle = io.open(root .. "/" .. relative, "r")
    if not handle then return nil end
    local body = handle:read("*a")
    handle:close()
    return body
  end

  function http.get(url)
    local body = http.serve(url)
    if not body then return nil, "404 not found: " .. url end
    return {
      readAll = function() return body end,
      close = function() return true end,
    }
  end

  return http
end

--------------------------------------------------------------------------
-- The host
--------------------------------------------------------------------------

function craftos.new(options)
  options = options or {}
  local host = setmetatable({
    fs = newFilesystem(),
    textutils = newTextutils(),
    http = newHttp(options.raw_prefix, options.root or "."),
    output = {},
    errors = {},
  }, Host)
  return host
end

-- run loads a CC:Tweaked program with only the globals it is allowed to see.
function Host:run(program, arguments)
  local environment = {
    fs = self.fs,
    http = self.http,
    textutils = self.textutils,
    print = function(...)
      local parts = {}
      for index = 1, select("#", ...) do parts[index] = tostring(select(index, ...)) end
      self.output[#self.output + 1] = table.concat(parts, " ")
    end,
    printError = function(...)
      local parts = {}
      for index = 1, select("#", ...) do parts[index] = tostring(select(index, ...)) end
      self.errors[#self.errors + 1] = table.concat(parts, " ")
    end,
    write = function(text) self.output[#self.output + 1] = tostring(text) end,
    -- Pure standard library only. Anything else ccpm reached for would be a
    -- dependency it never declared.
    assert = assert, error = error, pairs = pairs, ipairs = ipairs, next = next,
    select = select, type = type, tostring = tostring, tonumber = tonumber,
    setmetatable = setmetatable, getmetatable = getmetatable,
    rawget = rawget, rawset = rawset, pcall = pcall, xpcall = xpcall,
    string = string, table = table, math = math, os = { time = function() return 0 end },
  }

  local chunk
  if setfenv then
    chunk = assert(loadfile(program))
    setfenv(chunk, environment)
  else
    chunk = assert(loadfile(program, "t", environment))
  end
  -- unpack has to be the whole call expression, or Lua truncates it to one
  -- value and the program sees only its first argument.
  local unpackAll = table.unpack or unpack
  return chunk(unpackAll(arguments or {}))
end

function Host:printed()
  return table.concat(self.output, "\n")
end

return craftos
