-- The enrolled link: the only protocol surface callers above this package use.
--
-- A caller sends a semantic message and receives a validated one. It never
-- calculates a MAC, a counter, a body hash, or an operational channel, and it
-- never sees a canonical form. Transport, clock, and channel handling arrive as
-- injected adapters so the runtime can supply real modems in Milestone 3 while
-- tests supply fakes here.

local internal = ...
local frame = internal("frame")
local limits = internal("limits")
local errors = internal("errors")
local schema = internal("schema")

local link = {}

local Link = {}
Link.__index = Link

-- open wraps an established Authenticated Session in the request/notify/serve
-- interface. `transport` must provide send(text), receive(timeoutMs), close().
function link.open(options)
  assert(options and options.session, "link requires an established session")
  assert(options.transport and type(options.transport.send) == "function"
    and type(options.transport.receive) == "function",
    "link requires a transport adapter with send and receive")
  assert(options.clock and type(options.clock.now) == "function",
    "link requires a clock adapter with now()")

  local prefix = options.request_id_prefix or "req"
  assert(schema.scalars.id(prefix .. "-0"), "request_id_prefix must form a CraftNet ID")

  return setmetatable({
    session = options.session,
    transport = options.transport,
    clock = options.clock,
    prefix = prefix,
    defaultTimeout = options.default_timeout_ms or 5000,
    maximumInFlight = options.maximum_in_flight or limits.RELATIONSHIP_IN_FLIGHT,
    nextRequestNumber = options.first_request_number or 1,
    inFlight = 0,
    pending = {},
    closed = false,
  }, Link)
end

function Link:isClosed()
  return self.closed
end

-- allocateRequestId draws from a per-link counter. A Request ID is unique for
-- the issuing identity across its persisted counter lifetime, so the runtime
-- seeds first_request_number from durable state after a restart.
function Link:allocateRequestId()
  local identifier = self.prefix .. "-" .. self.nextRequestNumber
  self.nextRequestNumber = self.nextRequestNumber + 1
  return identifier
end

local function send(self, kind, body, requestId)
  local text, code, message = self.session:seal(kind, body, requestId)
  if not text then return nil, code, message end
  local ok, sendCode, sendMessage = self.transport:send(text)
  if ok == false then
    return nil, sendCode or "upstream_unavailable", sendMessage or "transport rejected the frame"
  end
  return true
end

-- notify sends a message that expects no terminal response.
function Link:notify(kind, body)
  if self.closed then return nil, "upstream_unavailable", "link is closed" end
  return send(self, kind, body, nil)
end

-- deliver hands an inbound message that is not the awaited reply to the serve
-- handler when one is installed, and otherwise buffers it for the next serve.
function Link:deliver(message)
  if self.handler then
    local replyKind, replyBody = self.handler(message)
    if replyKind then send(self, replyKind, replyBody, message.request_id) end
  else
    self.pending[#self.pending + 1] = message
  end
end

-- request sends one correlated message and waits for its reply. Excess work
-- fails with `busy` rather than being queued without bound.
function Link:request(kind, body, timeoutMs)
  if self.closed then return nil, "upstream_unavailable", "link is closed" end
  if self.inFlight >= self.maximumInFlight then
    return nil, "busy", "in-flight capacity of " .. self.maximumInFlight .. " is exhausted"
  end

  local requestId = self:allocateRequestId()
  local ok, code, message = send(self, kind, body, requestId)
  if not ok then return nil, code, message end

  self.inFlight = self.inFlight + 1
  local deadline = self.clock:now() + (timeoutMs or self.defaultTimeout)

  while true do
    local remaining = deadline - self.clock:now()
    if remaining <= 0 then
      self.inFlight = self.inFlight - 1
      return nil, "request_timeout", "no terminal response for " .. requestId
    end

    local text = self.transport:receive(remaining)
    if text == nil then
      self.inFlight = self.inFlight - 1
      return nil, "request_timeout", "no terminal response for " .. requestId
    end

    local inbound, inboundCode, inboundMessage = self.session:open(text)
    if inbound then
      if inbound.request_id == requestId then
        self.inFlight = self.inFlight - 1
        if inbound.kind == "error" then
          return nil, rawget(inbound.body, "code"), rawget(inbound.body, "message")
        end
        return inbound
      end
      self:deliver(inbound)
    else
      -- A frame that fails validation is dropped rather than answered: an
      -- attacker learns nothing, and the awaited reply may still arrive.
      self.lastRejection = { code = inboundCode, message = inboundMessage }
    end
  end
end

-- serve installs the inbound handler and drains anything already buffered.
-- The handler returns (kind, body) to reply, or nil to stay silent.
function Link:serve(handler)
  assert(type(handler) == "function", "serve requires a handler function")
  self.handler = handler
  local buffered = self.pending
  self.pending = {}
  for index = 1, #buffered do
    local message = buffered[index]
    local replyKind, replyBody = handler(message)
    if replyKind then send(self, replyKind, replyBody, message.request_id) end
  end
end

-- pump processes one inbound frame, for a runtime that owns its own event loop.
function Link:pump(timeoutMs)
  if self.closed then return nil, "upstream_unavailable", "link is closed" end
  local text = self.transport:receive(timeoutMs or self.defaultTimeout)
  if text == nil then return nil, "request_timeout", "no frame arrived" end
  local inbound, code, message = self.session:open(text)
  if not inbound then
    self.lastRejection = { code = code, message = message }
    return nil, code, message
  end
  self:deliver(inbound)
  return inbound
end

-- replyError answers a correlated request with a catalog error.
function Link:replyError(requestId, code, message, details)
  return send(self, "error", errors.new(code, message, details), requestId)
end

function Link:close()
  if self.closed then return true end
  self.closed = true
  self.handler = nil
  self.pending = {}
  if type(self.transport.close) == "function" then self.transport:close() end
  return true
end

return link
