-- The CraftOS terminal adapter.
--
-- The screen is deliberately terse: role, name, identity, Connectivity State,
-- and the latest actionable error. It is drawn in full each time rather than
-- scrolled, so a glance always shows the current truth rather than a history.

local adapter = {}

local Screen = {}
Screen.__index = Screen

function adapter.new(target)
  return setmetatable({ target = target or term }, Screen)
end

function Screen:render(lines)
  local target = self.target
  target.clear()
  for index, line in ipairs(lines) do
    target.setCursorPos(1, index)
    target.write(line)
  end
  local _, height = target.getSize()
  target.setCursorPos(1, math.min(#lines + 1, height))
  return true
end

return adapter
