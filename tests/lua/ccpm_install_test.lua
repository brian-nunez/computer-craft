-- Installing a role package on a clean Computer.
--
-- ccpm is what actually puts CraftNet on a Computer, so "it resolves" is not
-- something to take on trust from the manifests. This runs the real ccpm.lua
-- inside a fake CraftOS -- a fake filesystem, a fake http that serves this
-- repository's own registry and manifests, and nothing else -- and checks what
-- ends up in the lock file and on disk.

local fakeCraftOS = require("tests.lua.support.craftos")

local RAW_PREFIX = "https://raw.githubusercontent.com/brian-nunez/computer-craft/main/"

-- install runs ccpm exactly as a player would, against this checkout.
local function install(name, constraint)
  local os = fakeCraftOS.new({ raw_prefix = RAW_PREFIX, root = "." })
  os:run("ccpm.lua", { "install", name, constraint })
  return os
end

local function lockOf(os)
  local body = os.fs.files["/.ccpm/lock.json"]
  assert(body, "ccpm wrote no lock file")
  return os.textutils.unserialiseJSON(body)
end

test("installing a Customer Router brings every dependency into the lock file", function()
  local os = install("craftnet-router")
  local lock = lockOf(os)

  for _, expected in ipairs({
    "craftnet-router", "craftnet-runtime", "craftnet-core", "craftnet-protocol",
    "networking", "peripheral-discovery",
  }) do
    assertTrue(lock.packages[expected] ~= nil,
      expected .. " is missing from the lock file")
    assertEqual(type(lock.packages[expected].version), "string", expected .. " has a version")
  end
  assertEqual(lock.roots["craftnet-router"], "*", "the requested package is recorded as a root")
end)

test("installing a Computer brings every dependency too", function()
  local lock = lockOf(install("craftnet-computer"))
  for _, expected in ipairs({
    "craftnet-computer", "craftnet-runtime", "craftnet-core", "craftnet-protocol",
    "networking", "peripheral-discovery",
  }) do
    assertTrue(lock.packages[expected] ~= nil, expected .. " is missing from the lock file")
  end
end)

test("every file a manifest lists actually lands on the Computer", function()
  local os = install("craftnet-router")
  local lock = lockOf(os)

  local placed = 0
  for name, entry in pairs(lock.packages) do
    local manifest = os.textutils.unserialiseJSON(
      os.http.serve(RAW_PREFIX .. "packages/" .. name .. "/" .. entry.version .. ".json"))
    for file in pairs(manifest.files) do
      local path = "/.ccpm/packages/" .. name .. "/" .. entry.version .. "/" .. file
      assertTrue(os.fs.files[path] ~= nil, path .. " was not installed")
      assertTrue(#os.fs.files[path] > 0, path .. " is empty")
      placed = placed + 1
    end
  end
  assertTrue(placed >= 30, "a role install places the whole dependency tree (" .. placed .. " files)")
end)

-- materialize writes what ccpm installed onto the real disk, so the installed
-- copies can actually be loaded. Reading them out of a table would prove only
-- that bytes arrived; running them proves the manifest listed everything a
-- package needs.
local function materialize(host)
  local root = assert(os.getenv("CRAFTNET_TEST_TMPDIR"),
    "CRAFTNET_TEST_TMPDIR must be set by the test entry point")
  root = root .. "/ccpm-install"
  os.execute("rm -rf '" .. root .. "'")

  local paths = {}
  for path in pairs(host.fs.files) do paths[#paths + 1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do
    local full = root .. path
    os.execute("mkdir -p '" .. full:match("^(.*)/[^/]*$") .. "'")
    local handle = assert(io.open(full, "w"))
    handle:write(host.fs.files[path])
    handle:close()
  end
  return root
end

test("an installed role package runs from its locked path", function()
  local host = install("craftnet-router")
  local lock = lockOf(host)
  local root = materialize(host)

  local function installedPath(name, file)
    return root .. "/.ccpm/packages/" .. name .. "/" .. lock.packages[name].version
      .. "/" .. (file or "init.lua")
  end

  -- Load the installed copies, not the checkout. The sibling loader resolves
  -- against each file's own directory, so a package that shipped an incomplete
  -- file list fails right here.
  local protocol = dofile(installedPath("craftnet-protocol"))
  assertEqual(protocol.name, "craftnet-protocol", "the protocol package loaded")
  assertTrue(protocol.validate.customerAddress("192.168.1.20"), "and its modules came with it")

  local core = dofile(installedPath("craftnet-core")).withProtocol(protocol)
  assertEqual(core.name, "craftnet-core", "the core package loaded")
  assertTrue(core.newEngine({ role = "router" }) ~= nil, "and it builds an engine")

  local runtime = dofile(installedPath("craftnet-runtime"))
    .withPackages({ protocol = protocol, core = core })
  assertEqual(runtime.name, "craftnet-runtime", "the runtime package loaded")

  local routerPackage = dofile(installedPath("craftnet-router"))
    .withPackages({ protocol = protocol, core = core, runtime = runtime })
  assertEqual(routerPackage.name, "craftnet-router", "the role package loaded")
  assertTrue(type(routerPackage.new) == "function", "and it can build a router")
  assertTrue(#routerPackage.wizard.questions > 0, "with its setup questions")
end)

test("a package outside the registry is refused rather than guessed at", function()
  local os = fakeCraftOS.new({ raw_prefix = RAW_PREFIX, root = "." })
  os:run("ccpm.lua", { "install", "craftnet-nonsense" })
  assertTrue(os.fs.files["/.ccpm/lock.json"] == nil, "nothing was locked")
  assertTrue(table.concat(os.errors, "\n"):find("unknown package", 1, true) ~= nil,
    "and the failure names the problem")
end)

test("installing twice keeps one entry per package", function()
  local os = fakeCraftOS.new({ raw_prefix = RAW_PREFIX, root = "." })
  os:run("ccpm.lua", { "install", "craftnet-router" })
  os:run("ccpm.lua", { "install", "craftnet-computer" })

  local lock = lockOf(os)
  assertEqual(type(lock.packages["craftnet-runtime"].version), "string",
    "the shared dependency is present once")
  assertTrue(lock.roots["craftnet-router"] ~= nil, "both roots are recorded")
  assertTrue(lock.roots["craftnet-computer"] ~= nil, "both roots are recorded")
end)
