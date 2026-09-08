-- ccpm: a small package manager for CC:Tweaked.
-- Configure REGISTRY_URL before publishing this file.

local REGISTRY_URL = "https://raw.githubusercontent.com/brian-nunez/computer-craft/main/registry.json"
local ROOT = "/.ccpm"
local PACKAGE_ROOT = ROOT .. "/packages"
local LOCK_PATH = ROOT .. "/lock.json"

local args = { ... }

local function fail(message)
	printError("ccpm: " .. message)
	return false
end

local function request(url)
	local response, message = http.get(url)
	if not response then
		error("download failed: " .. tostring(message), 0)
	end
	local body = response.readAll()
	response.close()
	return body
end

local function decode(body, source)
	local value, message = textutils.unserialiseJSON(body)
	if value == nil then
		error("invalid JSON in " .. source .. ": " .. tostring(message), 0)
	end
	return value
end

local function readJSON(path, fallback)
	if not fs.exists(path) then
		return fallback
	end
	local handle = assert(fs.open(path, "r"))
	local body = handle.readAll()
	handle.close()
	return decode(body, path)
end

local function writeJSON(path, value)
	local parent = fs.getDir(path)
	if parent ~= "" then
		fs.makeDir(parent)
	end
	local temporary = path .. ".tmp"
	local handle = assert(fs.open(temporary, "w"))
	handle.write(textutils.serialiseJSON(value))
	handle.close()
	if fs.exists(path) then
		fs.delete(path)
	end
	fs.move(temporary, path)
end

local function parseVersion(version)
	local major, minor, patch = tostring(version):match("^(%d+)%.(%d+)%.(%d+)$")
	if not major then
		return nil
	end
	return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function compareVersions(left, right)
	local a, b = parseVersion(left), parseVersion(right)
	if not a or not b then
		error("versions must use MAJOR.MINOR.PATCH", 0)
	end
	for index = 1, 3 do
		if a[index] < b[index] then
			return -1
		end
		if a[index] > b[index] then
			return 1
		end
	end
	return 0
end

local function satisfies(version, constraint)
	constraint = constraint or "*"
	if constraint == "*" then
		return true
	end
	local operator, wanted = constraint:match("^(%^)(.+)$")
	if not operator then
		operator, wanted = constraint:match("^(~)(.+)$")
	end
	if not operator then
		operator, wanted = constraint:match("^(>=)(.+)$")
	end
	if not operator then
		operator, wanted = constraint:match("^(>)(.+)$")
	end
	if not operator then
		operator, wanted = constraint:match("^(<=)(.+)$")
	end
	if not operator then
		operator, wanted = constraint:match("^(<)(.+)$")
	end
	if not operator then
		operator, wanted = "=", constraint
	end
	local current, target = parseVersion(version), parseVersion(wanted)
	if not current or not target then
		error("invalid version constraint: " .. constraint, 0)
	end
	local comparison = compareVersions(version, wanted)
	if operator == "=" then
		return comparison == 0
	end
	if operator == ">=" then
		return comparison >= 0
	end
	if operator == ">" then
		return comparison > 0
	end
	if operator == "<=" then
		return comparison <= 0
	end
	if operator == "<" then
		return comparison < 0
	end
	if operator == "~" then
		return comparison >= 0 and current[1] == target[1] and current[2] == target[2]
	end
	if target[1] > 0 then
		return comparison >= 0 and current[1] == target[1]
	end
	if target[2] > 0 then
		return comparison >= 0 and current[1] == 0 and current[2] == target[2]
	end
	return comparison >= 0 and current[1] == 0 and current[2] == 0 and current[3] == target[3]
end

local function selectVersion(package, constraints)
	local candidates = {}
	for version in pairs(package.versions or {}) do
		local accepted = true
		for _, constraint in ipairs(constraints) do
			if not satisfies(version, constraint) then
				accepted = false
				break
			end
		end
		if accepted then
			candidates[#candidates + 1] = version
		end
	end
	table.sort(candidates, function(a, b)
		return compareVersions(a, b) > 0
	end)
	return candidates[1]
end

local function resolve(registry, requested)
	local constraints, selected, manifests = {}, {}, {}
	local resolving = {}

	local function add(name, constraint, chain)
		if not registry.packages or not registry.packages[name] then
			error("unknown package '" .. name .. "' (required by " .. chain .. ")", 0)
		end
		constraints[name] = constraints[name] or {}
		constraints[name][#constraints[name] + 1] = constraint or "*"
		local version = selectVersion(registry.packages[name], constraints[name])
		if not version then
			error("no version of '" .. name .. "' satisfies all constraints", 0)
		end
		if resolving[name] then
			error("dependency cycle involving '" .. name .. "'", 0)
		end
		if selected[name] == version then
			return
		end

		selected[name] = version
		resolving[name] = true
		local entry = registry.packages[name].versions[version]
		local manifest = entry.manifest and decode(request(entry.manifest), entry.manifest) or entry
		manifests[name] = manifest
		for dependency, wanted in pairs(manifest.dependencies or {}) do
			add(dependency, wanted, name .. "@" .. version)
		end
		resolving[name] = nil
	end

	for name, constraint in pairs(requested) do
		add(name, constraint, "command line")
	end
	return selected, manifests
end

local function safeRelativePath(path)
	return type(path) == "string"
		and path ~= ""
		and path:sub(1, 1) ~= "/"
		and not path:find("..", 1, true)
		and not path:find("\\", 1, true)
end

local function install(name, constraint)
	print("Fetching registry...")
	local registry = decode(request(REGISTRY_URL), REGISTRY_URL)
	local selected, manifests = resolve(registry, { [name] = constraint or "*" })
	local staged = {}

	-- Download every file first, so a failed request does not leave a partial package.
	for packageName, version in pairs(selected) do
		local manifest = manifests[packageName]
		if manifest.name and manifest.name ~= packageName then
			error("manifest name mismatch for " .. packageName, 0)
		end
		for path, url in pairs(manifest.files or {}) do
			if not safeRelativePath(path) then
				error("unsafe package path: " .. tostring(path), 0)
			end
			staged[#staged + 1] = {
				path = PACKAGE_ROOT .. "/" .. packageName .. "/" .. version .. "/" .. path,
				body = request(url),
			}
		end
	end

	for _, file in ipairs(staged) do
		fs.makeDir(fs.getDir(file.path))
		local handle = assert(fs.open(file.path, "w"))
		handle.write(file.body)
		handle.close()
	end

	local lock = readJSON(LOCK_PATH, { packages = {}, roots = {} })
	lock.packages = lock.packages or {}
	lock.roots = lock.roots or {}
	lock.roots[name] = constraint or "*"
	for packageName, version in pairs(selected) do
		lock.packages[packageName] = { version = version }
	end
	writeJSON(LOCK_PATH, lock)
	for packageName, version in pairs(selected) do
		print("Installed " .. packageName .. "@" .. version)
	end
end

local function list()
	local lock = readJSON(LOCK_PATH, { packages = {} })
	local names = {}
	for name in pairs(lock.packages or {}) do
		names[#names + 1] = name
	end
	table.sort(names)
	if #names == 0 then
		print("No packages installed.")
		return
	end
	for _, name in ipairs(names) do
		print(name .. " " .. lock.packages[name].version)
	end
end

local function usage()
	print("Usage:")
	print("  ccpm install <package> [constraint]")
	print("  ccpm list")
	print("Constraints: *, 1.2.3, ^1.2.3, ~1.2.3, >=1.2.3, >, <=, <")
end

local ok, message = pcall(function()
	if args[1] == "install" and args[2] then
		install(args[2], args[3])
	elseif args[1] == "list" then
		list()
	else
		usage()
	end
end)
if not ok then
	fail(message)
end
