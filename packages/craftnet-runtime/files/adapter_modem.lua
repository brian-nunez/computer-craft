-- The modem transport.
--
-- This is where CraftNet meets a real peripheral, and it is deliberately the
-- dumbest layer in the package: open a channel, put bytes on it, take bytes
-- off it. It knows nothing about sessions, relationships, or CraftNet at all,
-- which is what lets everything above it be tested with a transport made of a
-- table.

local adapter = {}

local Modem = {}
Modem.__index = Modem

-- new selects a modem through the existing `networking` package, or takes one
-- already wrapped. Selection is deterministic: Ender first, then wired, then
-- ordinary wireless, ties broken by peripheral name.
function adapter.new(options)
  options = options or {}
  local modem = options.modem
  local name, kind = options.modem_name, options.modem_kind

  if not modem and options.networking then
    local selected = options.networking.selectModem(options.selection or {})
    assert(selected, "no modem is attached to this Computer")
    modem, name, kind = selected.wrapped, selected.name, selected.kind
  end
  assert(type(modem) == "table" and type(modem.transmit) == "function",
    "the modem transport needs a wrapped modem")

  return setmetatable({
    modem = modem,
    name = name,
    kind = kind,
  }, Modem)
end

function Modem:open(channel)
  if not self.modem.isOpen(channel) then self.modem.open(channel) end
  return true
end

function Modem:close(channel)
  if self.modem.isOpen(channel) then self.modem.close(channel) end
  return true
end

function Modem:transmit(channel, replyChannel, text)
  local ok, problem = pcall(self.modem.transmit, channel, replyChannel, text)
  if not ok then return nil, tostring(problem) end
  return true
end

-- receive waits for one modem message, or for the timeout. Anything that is not
-- a string on an open channel is ignored rather than surfaced: a shared channel
-- carries other programs' traffic too.
function Modem:receive(timeoutMs)
  local timer
  if timeoutMs and timeoutMs >= 0 then
    timer = os.startTimer(math.max(0, timeoutMs) / 1000)
  end

  while true do
    local event, first, channel, replyChannel, message = os.pullEvent()
    if event == "timer" and first == timer then
      return nil
    elseif event == "modem_message" and type(message) == "string" then
      if timer then os.cancelTimer(timer) end
      return channel, replyChannel, message
    elseif event == "peripheral_detach" and first == self.name then
      if timer then os.cancelTimer(timer) end
      return nil, "detached"
    end
  end
end

function Modem:describe()
  return { name = self.name, kind = self.kind }
end

return adapter
