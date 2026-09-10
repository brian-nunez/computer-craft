-- Locating the installed packages on a CC:Tweaked Computer.
--
-- ccpm records what it installed in a lock file, so a program finds its
-- dependencies the same way the `networking` package already does. This is the
-- one place a role package touches the filesystem to find code, and it is kept
-- apart from everything else so the rest of the package stays loadable from a
-- checkout during tests.

local bootstrap = {}

local LOCK_PATH = "/.ccpm/lock.json"
local PACKAGE_ROOT = "/.ccpm/packages"

function bootstrap.locked()
  local handle = fs.open(LOCK_PATH, "r")
  assert(handle, "ccpm lock file not found; install a role package first")
  local body = handle.readAll()
  handle.close()
  local lock = textutils.unserialiseJSON(body)
  assert(lock and lock.packages, "the ccpm lock file is unreadable")
  return lock
end

function bootstrap.load(name, file)
  local lock = bootstrap.lock or bootstrap.locked()
  bootstrap.lock = lock
  local entry = lock.packages[name]
  assert(entry, "missing dependency: " .. name .. "; run 'ccpm install' again")
  return dofile(PACKAGE_ROOT .. "/" .. name .. "/" .. entry.version .. "/" .. (file or "init.lua"))
end

-- packages loads the three shared packages, bound to each other in the one
-- order that makes sense: protocol, then core, then runtime.
function bootstrap.packages()
  local protocol = bootstrap.load("craftnet-protocol")
  local core = bootstrap.load("craftnet-core").withProtocol(protocol)
  local runtime = bootstrap.load("craftnet-runtime")
    .withPackages({ protocol = protocol, core = core })
  return { protocol = protocol, core = core, runtime = runtime }
end

-- adapters builds the real CraftOS adapters for a role.
function bootstrap.adapters(packages, options)
  options = options or {}
  local networking = bootstrap.load("networking")
  return {
    clock = packages.runtime.adapters.clock(),
    storage = packages.runtime.adapters.storage(options.root or "/craftnet"),
    screen = packages.runtime.adapters.screen(),
    transport = packages.runtime.adapters.modem({
      networking = networking,
      selection = options.selection,
    }),
  }
end

return bootstrap
