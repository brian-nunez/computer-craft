-- The ISP setup questions.
--
-- An ISP knows its own name before it has an identity, because the Central
-- Server is what assigns the identity. So the wizard asks for very little: a
-- name, and then the one-time token that buys a place in the World.

local internal = ...
local protocol = internal("protocol")

local wizard = {}

wizard.questions = {
  {
    key = "isp_name",
    prompt = "ISP name",
    example = "acme",
    validate = function(value)
      if not protocol.validate.normalizedName(value) then
        return nil, "an ISP name is 1 to 32 lowercase letters, digits, and internal hyphens"
      end
      return value
    end,
  },
  {
    key = "token",
    prompt = "ISP Enrollment Token",
    example = "W203-ZPY2-T9ZR-T1JX",
    validate = function(value)
      local normalized = protocol.tokens.normalize(value)
      if not normalized then
        return nil, "a token is " .. protocol.tokens.LENGTH
          .. " characters, usually written in groups of four"
      end
      return normalized
    end,
  },
}

function wizard.validate(key, value)
  for _, question in ipairs(wizard.questions) do
    if question.key == key then return question.validate(value) end
  end
  return nil, "'" .. tostring(key) .. "' is not a setup question"
end

-- settings is what the engine takes before enrollment. The identity, the
-- Provider Allocation, and the Operational Channel all arrive from the Central
-- Server, so none of them is asked for here.
function wizard.settings(answers, context)
  context = context or {}
  return {
    isp_id = context.isp_id or ("isp-" .. answers.isp_name),
    isp_name = answers.isp_name,
    world_id = context.world_id,
    central_id = context.central_id,
    provider_allocations = context.provider_allocations or {},
  }
end

return wizard
