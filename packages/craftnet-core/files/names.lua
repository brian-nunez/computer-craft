-- CraftNet Names.
--
-- Names are a delegated, case-insensitive hierarchy. Each role is authoritative
-- only for the labels immediately beneath it, so resolution walks upward until
-- it reaches an owner rather than consulting any central directory:
--
--   harvester                        local Customer Network
--   harvester.farm                   Customer Network within the current ISP
--   harvester.farm.acme              globally qualified within the World
--   harvester.farm.acme.craft        explicit CraftNet name
--   api.craft                        the External Application

local internal = ...
local protocol = internal("protocol")

local names = {}

local SUFFIX = "craft"
local EXTERNAL_HOST = "api"

names.SUFFIX = SUFFIX
names.EXTERNAL = EXTERNAL_HOST .. "." .. SUFFIX

-- normalize lowercases a name and rejects anything that is not a hierarchy of
-- normalized labels. Case insensitivity is a property of the name, so it is
-- applied once here rather than at every comparison.
function names.normalize(text)
  if type(text) ~= "string" or text == "" or #text > 253 then return nil end
  local lowered = string.lower(text)
  if string.sub(lowered, -1) == "." then return nil end
  local labels = {}
  for label in string.gmatch(lowered, "[^.]+") do
    if not protocol.validate.normalizedName(label) then return nil end
    labels[#labels + 1] = label
  end
  -- gmatch skips empty labels, so a doubled or leading dot has to be caught by
  -- rebuilding the name and comparing.
  if #labels == 0 or table.concat(labels, ".") ~= lowered then return nil end
  return lowered, labels
end

-- parse classifies a name against the scope it was asked in. `scope` names the
-- asking Computer's own Customer Network and ISP, which is what makes a bare
-- hostname meaningful.
function names.parse(text, scope)
  local normalized, labels = names.normalize(text)
  if not normalized then
    return nil, "invalid_message", "'" .. tostring(text) .. "' is not a CraftNet Name"
  end

  local explicit = labels[#labels] == SUFFIX
  if explicit then
    labels[#labels] = nil
    if #labels == 0 then
      return nil, "name_not_found", "the CraftNet suffix names nothing on its own"
    end
  end

  -- api.craft is the External Application and is never a Computer.
  if explicit and #labels == 1 and labels[1] == EXTERNAL_HOST then
    return { kind = "external", canonical = names.EXTERNAL, normalized = normalized }
  end

  if #labels == 1 then
    return {
      kind = "computer",
      hostname = labels[1],
      customer_network_name = scope and scope.customer_network_name,
      isp_name = scope and scope.isp_name,
      scope = "local",
      normalized = normalized,
    }
  end
  if #labels == 2 then
    return {
      kind = "computer",
      hostname = labels[1],
      customer_network_name = labels[2],
      isp_name = scope and scope.isp_name,
      scope = "isp",
      normalized = normalized,
    }
  end
  if #labels == 3 then
    return {
      kind = "computer",
      hostname = labels[1],
      customer_network_name = labels[2],
      isp_name = labels[3],
      scope = "world",
      normalized = normalized,
    }
  end
  return nil, "name_not_found", "a CraftNet Name has at most three labels before '.craft'"
end

-- canonical renders the fully qualified form a resolver answers with, so that
-- every caller sees the same spelling regardless of how it asked.
function names.canonical(hostname, customerNetworkName, ispName)
  return table.concat({ hostname, customerNetworkName, ispName, SUFFIX }, ".")
end

-- isLocal reports whether a parsed name refers to the Customer Network the
-- question was asked in. A bare hostname always is; a qualified one only when
-- both the network and the ISP agree.
function names.isLocal(parsed, scope)
  if parsed.kind ~= "computer" then return false end
  if parsed.scope == "local" then return true end
  if parsed.customer_network_name ~= scope.customer_network_name then return false end
  if parsed.scope == "isp" then return true end
  return parsed.isp_name == scope.isp_name
end

return names
