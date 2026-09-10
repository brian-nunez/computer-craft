-- The CraftOS filesystem adapter.
--
-- One of the four files in CraftNet that touch a CC:Tweaked global. Everything
-- above it works against this interface, which is what lets the whole runtime
-- be driven from a table in a test.

local adapter = {}

local Storage = {}
Storage.__index = Storage

-- new roots every path under one directory, so a role can never write outside
-- its own state area by passing a crafted name.
function adapter.new(root)
  root = root or "/craftnet"
  return setmetatable({ root = root }, Storage)
end

function Storage:resolve(path)
  assert(type(path) == "string" and path ~= "", "a storage path is required")
  assert(not path:find("%.%."), "a storage path may not climb out of its root")
  return fs.combine(self.root, path)
end

function Storage:read(path)
  local full = self:resolve(path)
  if not fs.exists(full) or fs.isDir(full) then return nil end
  local handle = fs.open(full, "r")
  if not handle then return nil end
  local contents = handle.readAll()
  handle.close()
  return contents
end

function Storage:write(path, contents)
  local full = self:resolve(path)
  local parent = fs.getDir(full)
  if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
  local handle, problem = fs.open(full, "w")
  if not handle then return nil, problem or "cannot open for writing" end
  handle.write(contents)
  handle.close()
  return true
end

-- move is a rename, which is what makes a snapshot swap atomic from the point
-- of view of anything reading it.
function Storage:move(from, to)
  local source = self:resolve(from)
  local destination = self:resolve(to)
  if not fs.exists(source) then return nil, "source does not exist" end
  if fs.exists(destination) then fs.delete(destination) end
  local ok, problem = pcall(fs.move, source, destination)
  if not ok then return nil, tostring(problem) end
  return true
end

function Storage:remove(path)
  local full = self:resolve(path)
  if fs.exists(full) then fs.delete(full) end
  return true
end

function Storage:exists(path)
  return fs.exists(self:resolve(path))
end

return adapter
