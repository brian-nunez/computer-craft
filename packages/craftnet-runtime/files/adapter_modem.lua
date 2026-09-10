-- The modem transport and its Logical Interfaces.
--
-- A Logical Interface binds one infrastructure role -- upstream, downstream, or
-- local -- to a modem and the channels it carries. An ISP reaches the Central
-- Server over an Ender modem and its Customer Routers over another; a Customer
-- Router faces its ISP over an Ender modem and its Computers over an ordinary
-- LAN modem. Which modem a frame leaves on is a property of the channel, not
-- something a caller has to know.
--
-- CraftOS raises `modem_message` for every open channel on every modem through
-- the same event queue, so one transport can serve several interfaces without
-- anything above it noticing. That is why this is still the dumbest layer in
-- the package: open a channel, put bytes on it, take bytes off it.

local adapter = {}

local Modem = {}
Modem.__index = Modem

-- The reference discovery channels. A wizard may choose others; these are what
-- the acceptance topology uses.
adapter.CENTRAL_DISCOVERY = 42000
adapter.ISP_DISCOVERY = 42001
adapter.LAN_DISCOVERY = 42002

-- new takes either one modem or a set of named interfaces:
--
--   adapter.new({ networking = networking })
--   adapter.new({ interfaces = {
--     { name = "upstream",   modem = ender, channels = { 42000 } },
--     { name = "downstream", modem = lan,   channels = { 42002 } },
--   } })
function adapter.new(options)
  options = options or {}
  local interfaces = {}

  if options.interfaces then
    for _, spec in ipairs(options.interfaces) do
      assert(type(spec.modem) == "table" and type(spec.modem.transmit) == "function",
        "a Logical Interface needs a wrapped modem")
      interfaces[#interfaces + 1] = {
        name = spec.name or ("interface-" .. #interfaces + 1),
        modem = spec.modem,
        modem_name = spec.modem_name,
        kind = spec.kind,
        channels = spec.channels or {},
      }
    end
  else
    local modem, name, kind = options.modem, options.modem_name, options.modem_kind
    if not modem and options.networking then
      local selected = options.networking.selectModem(options.selection or {})
      assert(selected, "no modem is attached to this Computer")
      modem, name, kind = selected.wrapped, selected.name, selected.kind
    end
    assert(type(modem) == "table" and type(modem.transmit) == "function",
      "the modem transport needs a wrapped modem")
    interfaces[1] = { name = "default", modem = modem, modem_name = name, kind = kind }
  end

  local transport = setmetatable({
    interfaces = interfaces,
    byChannel = {},
    observers = {},
  }, Modem)

  -- A channel named by an interface belongs to it. Anything else falls to the
  -- first interface, which is what a single-modem Computer always uses.
  for _, interface in ipairs(interfaces) do
    for _, channel in ipairs(interface.channels) do
      transport.byChannel[channel] = interface
    end
  end
  return transport
end

function Modem:interfaceFor(channel)
  return self.byChannel[channel] or self.interfaces[1]
end

function Modem:open(channel)
  local interface = self:interfaceFor(channel)
  if not interface.modem.isOpen(channel) then interface.modem.open(channel) end
  return true
end

function Modem:close(channel)
  local interface = self:interfaceFor(channel)
  if interface.modem.isOpen(channel) then interface.modem.close(channel) end
  return true
end

function Modem:transmit(channel, replyChannel, text)
  local interface = self:interfaceFor(channel)
  local ok, problem = pcall(interface.modem.transmit, channel, replyChannel, text)
  if not ok then return nil, tostring(problem) end
  return true
end

-- observe registers something else that wants CraftOS events. A Central Server
-- holds a WebSocket as well as its modems, and CraftOS delivers both through
-- one queue -- so an event this transport does not recognise has to be offered
-- somewhere rather than discarded, or the Gateway would never hear anything
-- while the role was waiting on a modem.
--
-- An observer answers whether the event was its own. Nothing else about it is
-- this transport's business.
function Modem:observe(observer)
  assert(type(observer) == "function", "an event observer must be a function")
  self.observers[#self.observers + 1] = observer
  return self
end

function Modem:offer(...)
  for _, observer in ipairs(self.observers) do
    if observer(...) then return true end
  end
  return false
end

-- receive waits for one modem message on any interface, or for the timeout.
-- Anything that is not a string is ignored rather than surfaced: a shared
-- channel carries other programs' traffic too.
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
    elseif event == "peripheral_detach" then
      for _, interface in ipairs(self.interfaces) do
        if interface.modem_name == first then
          if timer then os.cancelTimer(timer) end
          return nil, "detached", interface.name
        end
      end
    else
      -- Not a modem event. Someone else may be waiting for it; the loop carries
      -- on either way, because whatever it was is not a frame for this caller.
      self:offer(event, first, channel, replyChannel, message)
    end
  end
end

-- describe is what a screen or a diagnostic shows: which modem serves which
-- role, and nothing about what travels on it.
function Modem:describe()
  local described = {}
  for index, interface in ipairs(self.interfaces) do
    described[index] = {
      name = interface.name,
      modem = interface.modem_name,
      kind = interface.kind,
      channels = interface.channels,
    }
  end
  return described
end

return adapter
