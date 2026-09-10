-- The terse local screen.
--
-- An in-world screen is deliberately small: it answers "what is this computer,
-- is it connected, and what is wrong right now" and nothing else. The dashboard
-- is where an Operator investigates. Rendering produces lines rather than
-- drawing them, so the wording is testable and the adapter stays trivial.

local screen = {}

local ROLE_LABELS = {
  central = "Central Server",
  isp = "ISP",
  router = "Customer Router",
  computer = "Computer",
}

local STATE_LABELS = {
  connecting = "connecting",
  ready = "ready",
  degraded = "degraded",
  disconnected = "disconnected",
  revoked = "revoked",
}

screen.ROLE_LABELS = ROLE_LABELS
screen.STATE_LABELS = STATE_LABELS

local function pick(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil and value ~= "" then return value end
  end
  return nil
end

-- summarize reduces a role's state to what belongs on a screen. Nothing secret
-- reaches it: credentials, passwords, and tokens are never part of the summary.
function screen.summarize(role, state, status)
  state = state or {}
  status = status or {}
  local name = pick(state.hostname, state.customer_network_name, state.isp_name, state.central_id)
  local identity = pick(
    state.computer_id, state.router_id, state.isp_id, state.central_id)
  return {
    role = role,
    role_label = ROLE_LABELS[role] or role,
    name = name,
    identity = identity,
    address = pick(state.address, state.router_address, state.provider_address),
    connectivity_state = status.connectivity_state or "connecting",
    revision = state.revision or 0,
    error = status.error,
  }
end

-- render returns the lines to draw, shortest useful form first.
function screen.render(summary)
  local lines = {}
  local heading = summary.role_label
  if summary.name then heading = heading .. ": " .. summary.name end
  lines[#lines + 1] = heading

  if summary.identity then
    lines[#lines + 1] = "id  " .. summary.identity
  end
  if summary.address then
    lines[#lines + 1] = "at  " .. summary.address
  end

  lines[#lines + 1] = "net " .. (STATE_LABELS[summary.connectivity_state]
    or summary.connectivity_state) .. "  rev " .. summary.revision

  if summary.error then
    -- The latest actionable error, phrased for a player rather than a log.
    local text = summary.error.message or summary.error.code
    lines[#lines + 1] = "!   " .. text
  end
  return lines
end

-- lines is the whole path in one call, for a runtime that just wants text.
function screen.lines(role, state, status)
  return screen.render(screen.summarize(role, state, status))
end

return screen
