-- The modem links adapter.
--
-- This is where CraftNet meets a real peripheral. It selects a modem through
-- the existing `networking` package, carries sealed frames on assigned
-- operational channels, and turns a CraftOS `modem_message` event into the
-- validated message the runtime feeds to the engine.
--
-- It carries relationships that already exist. First enrollment -- discovery,
-- the one-time token or LAN Password, and the credential that comes out of it
-- -- belongs to the role packages and their setup wizards, so this adapter is
-- handed a relationship credential rather than earning one.

local internal = ...
local protocol = internal("protocol")

local adapter = {}

local Links = {}
Links.__index = Links

-- new binds the adapter to one modem. `networking` is passed in rather than
-- located, keeping the dependency explicit and this file testable in principle.
function adapter.new(options)
  assert(type(options) == "table", "the modem adapter needs options")
  local modem = options.modem
  if not modem and options.networking then
    local selected = options.networking.selectModem(options.selection or {})
    assert(selected, "no modem is attached to this Computer")
    modem = selected.wrapped
    options.modem_name = selected.name
    options.modem_kind = selected.kind
  end
  assert(type(modem) == "table" and type(modem.transmit) == "function",
    "the modem adapter needs a wrapped modem")

  return setmetatable({
    modem = modem,
    modemName = options.modem_name,
    modemKind = options.modem_kind,
    identity = options.identity,
    discoveryChannel = options.discovery_channel,
    relationships = {},
    byChannel = {},
    pending = {},
  }, Links)
end

--------------------------------------------------------------------------
-- Relationships
--------------------------------------------------------------------------

-- adopt registers an established relationship: its credential, its assigned
-- operational channel, and the live session the handshake produced.
function Links:adopt(spec)
  assert(protocol.validate.identifier(spec.relationship_id), "relationship_id must be an identifier")
  assert(protocol.validate.channel(spec.channel), "an operational channel is required")

  local entry = {
    relationship_id = spec.relationship_id,
    credential = spec.credential,
    channel = spec.channel,
    reply_channel = spec.reply_channel or spec.channel,
    role = spec.role,
    id = spec.id,
    direction = spec.direction or "child",
    session = spec.session,
  }
  self.relationships[spec.relationship_id] = entry
  self.byChannel[spec.channel] = entry
  self.modem.open(spec.channel)
  return entry
end

function Links:forget(relationshipId)
  local entry = self.relationships[relationshipId]
  if not entry then return false end
  self.relationships[relationshipId] = nil
  if self.byChannel[entry.channel] == entry then
    self.byChannel[entry.channel] = nil
    self.modem.close(entry.channel)
  end
  return true
end

--------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------

-- send seals one message under the relationship's live session and puts it on
-- the wire. A caller never sees the MAC, the counter, or the canonical form.
function Links:send(relationshipId, messageKind, body, requestId)
  local entry = self.relationships[relationshipId]
  if not entry then return nil, "no such relationship" end
  if not entry.session then return nil, "that relationship has no live session" end

  local text, code, problem = entry.session:seal(messageKind, body, requestId)
  if not text then return nil, (problem or code) end

  local ok, transmitProblem = pcall(self.modem.transmit, entry.channel, entry.reply_channel, text)
  if not ok then return nil, tostring(transmitProblem) end
  return true
end

--------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------

-- poll waits for one relevant CraftOS event and returns it in the shape the
-- runtime understands, or nil when the timeout elapses. A frame that fails
-- validation is dropped rather than answered: an attacker on a shared channel
-- learns nothing from silence.
function Links:poll(timeoutMs)
  if #self.pending > 0 then
    return table.remove(self.pending, 1)
  end

  local timer
  if timeoutMs and timeoutMs >= 0 then
    timer = os.startTimer(math.max(0, timeoutMs) / 1000)
  end

  while true do
    local event, first, channel, replyChannel, message = os.pullEvent()
    if event == "timer" and first == timer then
      return nil
    elseif event == "modem_message" then
      local entry = self.byChannel[channel]
      if entry and entry.session and type(message) == "string" then
        local inbound, code, problem = entry.session:open(message)
        if inbound then
          if timer then os.cancelTimer(timer) end
          return {
            kind = "message",
            relationship_id = entry.relationship_id,
            message = {
              kind = inbound.kind,
              body = inbound.body,
              request_id = inbound.request_id,
            },
          }
        end
        self.lastRejection = { code = code, message = problem, channel = channel }
      end
    elseif event == "peripheral_detach" and first == self.modemName then
      if timer then os.cancelTimer(timer) end
      return { kind = "link_down", relationship_id = self:anyRelationshipId() }
    end
  end
end

function Links:anyRelationshipId()
  for relationshipId in pairs(self.relationships) do return relationshipId end
  return nil
end

--------------------------------------------------------------------------
-- Reconnection
--------------------------------------------------------------------------

-- connect re-establishes a relationship the runtime has decided is
-- disconnected. It always builds a fresh Authenticated Session from the durable
-- relationship credential; an old session is never resumed, and the parent
-- refuses a session identifier or nonce it has already seen.
function Links:connect(relationshipId)
  local entry = self.relationships[relationshipId]
  if not entry then return nil, "no such relationship" end
  if not entry.credential then
    return nil, "that relationship has no durable credential to reconnect with"
  end
  if entry.direction ~= "parent" then
    -- Children reconnect to us, not the other way round.
    return nil, "only a parent relationship is reconnected from this side"
  end
  if type(self.establish) ~= "function" then
    -- The handshake belongs to the role package, which supplies it here once
    -- its wizard has produced the credential. Until then a reconnection is
    -- reported as unavailable rather than faked.
    return nil, "no session handshake has been installed"
  end
  local session, problem = self:establish(entry)
  if not session then return nil, problem or "the handshake did not complete" end
  entry.session = session
  return true
end

-- installHandshake is how a role package supplies the session exchange. Keeping
-- it injected means this adapter never needs to know which role it is serving.
function Links:installHandshake(establish)
  assert(type(establish) == "function", "a handshake must be a function")
  self.establish = establish
  return self
end

return adapter
