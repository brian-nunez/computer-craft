-- The links adapter: sessions over a transport.
--
-- This is what the runtime means by "links". It holds one Authenticated Session
-- per relationship, seals outbound messages, opens inbound ones, and turns a
-- frame that arrives before any session exists into whatever the role package
-- installed to handle it.
--
-- It works over any transport that can open a channel and move strings, so the
-- same code runs on a real modem in Minecraft and on a table in a test. That is
-- the whole point: the vertical slice a Milestone 4 gate asks for should be
-- proved on the code that ships, not on a stand-in for it.

local internal = ...
local protocol = internal("protocol")

local links = {}

local Links = {}
Links.__index = Links

function links.new(options)
  assert(type(options) == "table", "a links adapter needs options")
  local transport = options.transport
  assert(type(transport) == "table" and type(transport.transmit) == "function"
    and type(transport.receive) == "function" and type(transport.open) == "function",
    "a links adapter needs a transport with open, transmit, and receive")

  return setmetatable({
    transport = transport,
    relationships = {},
    byChannel = {},
    queued = {},
    -- A frame with no live session is not an error: it is how enrollment and
    -- reconnection begin. The role package says what to do with one.
    handshakeHandler = options.on_handshake,
    connectHandler = options.on_connect,
    rejections = 0,
  }, Links)
end

--------------------------------------------------------------------------
-- Relationships
--------------------------------------------------------------------------

-- adopt registers an established relationship. `session` comes from a completed
-- handshake; `credential` is what a later reconnect will build a fresh one from.
function Links:adopt(spec)
  assert(protocol.validate.identifier(spec.relationship_id),
    "relationship_id must be a CraftNet identifier")
  assert(protocol.validate.channel(spec.channel), "an operational channel is required")

  local entry = self.relationships[spec.relationship_id] or {}
  entry.relationship_id = spec.relationship_id
  entry.channel = spec.channel
  entry.reply_channel = spec.reply_channel or spec.channel
  entry.role = spec.role or entry.role
  entry.id = spec.id or entry.id
  entry.direction = spec.direction or entry.direction or "child"
  entry.credential = spec.credential or entry.credential
  entry.session = spec.session or entry.session

  self.relationships[spec.relationship_id] = entry
  self.byChannel[entry.channel] = self.byChannel[entry.channel] or {}
  self.byChannel[entry.channel][spec.relationship_id] = entry
  self.transport:open(entry.channel)

  -- The runtime learns about the relationship through the same input path a
  -- modem event would have used, so nothing is special-cased for a wizard.
  self.queued[#self.queued + 1] = {
    kind = "link_up",
    relationship_id = entry.relationship_id,
    peer_role = entry.role,
    peer_id = entry.id,
    direction = entry.direction,
  }
  return entry
end

function Links:get(relationshipId)
  return self.relationships[relationshipId]
end

function Links:forget(relationshipId)
  local entry = self.relationships[relationshipId]
  if not entry then return false end
  self.relationships[relationshipId] = nil
  local onChannel = self.byChannel[entry.channel]
  if onChannel then onChannel[relationshipId] = nil end
  self.queued[#self.queued + 1] = { kind = "link_down", relationship_id = relationshipId }
  return true
end

function Links:count()
  local total = 0
  for _ in pairs(self.relationships) do total = total + 1 end
  return total
end

--------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------

function Links:send(relationshipId, messageKind, body, requestId)
  local entry = self.relationships[relationshipId]
  if not entry then return nil, "no such relationship" end
  if not entry.session then return nil, "that relationship has no live session" end

  local text, code, problem = entry.session:seal(messageKind, body, requestId)
  if not text then return nil, (problem or code) end
  return self.transport:transmit(entry.channel, entry.reply_channel, text)
end

--------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------

-- open tries a frame against every session listening on the channel it arrived
-- on. Two relationships can share a LAN channel, so the frame itself -- through
-- its relationship, its session, and its MAC -- is what decides whose it is.
function Links:open(channel, text)
  local candidates = self.byChannel[channel]
  if not candidates then return nil end
  for _, entry in pairs(candidates) do
    if entry.session then
      local inbound = entry.session:open(text)
      if inbound then
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
    end
  end
  return nil
end

-- poll returns the next event for the runtime: a queued lifecycle change, an
-- authenticated message, or nothing. A frame that authenticates against no
-- session is offered to the handshake handler and otherwise dropped in silence,
-- because answering it would tell a listener on a shared channel something.
function Links:poll(timeoutMs)
  if #self.queued > 0 then
    return table.remove(self.queued, 1)
  end

  local channel, replyChannel, text = self.transport:receive(timeoutMs)
  if not channel or type(text) ~= "string" then return nil end

  local message = self:open(channel, text)
  if message then return message end

  if self.handshakeHandler then
    -- What the handler reports is for diagnostics, not for the engine: an
    -- enrollment step is not a CraftNet input. Anything the exchange actually
    -- established arrives through the queue, the same way every other
    -- relationship does.
    self.lastHandshake = self.handshakeHandler(self, channel, replyChannel, text)
    if #self.queued > 0 then return table.remove(self.queued, 1) end
    return nil
  end

  self.rejections = self.rejections + 1
  return nil
end

--------------------------------------------------------------------------
-- Reconnection
--------------------------------------------------------------------------

-- connect asks the role package to build a fresh Authenticated Session from the
-- durable relationship credential. An old session is never resumed, and only
-- the upstream side reconnects.
function Links:connect(relationshipId)
  local entry = self.relationships[relationshipId]
  if not entry then return nil, "no such relationship" end
  if not entry.credential then
    return nil, "that relationship has no durable credential to reconnect with"
  end
  if not self.connectHandler then
    return nil, "no session handshake has been installed"
  end

  local session, problem = self.connectHandler(self, entry)
  if not session then return nil, problem or "the handshake did not complete" end
  entry.session = session
  self.queued[#self.queued + 1] = {
    kind = "link_up",
    relationship_id = entry.relationship_id,
    peer_role = entry.role,
    peer_id = entry.id,
    direction = entry.direction,
  }
  return true
end

-- pending reports how many lifecycle events are waiting for the runtime, so a
-- wizard can settle them before it hands control back.
function Links:pending()
  return #self.queued
end

function Links:onHandshake(handler)
  self.handshakeHandler = handler
  return self
end

function Links:onConnect(handler)
  self.connectHandler = handler
  return self
end

return links
