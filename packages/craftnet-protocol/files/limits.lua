-- CraftNet v1 wire limits.
--
-- Every bound the protocol states lives here so that a decoder, a frame writer,
-- and a test all read the same number. CraftNet performs no fragmentation: a
-- caller that exceeds a limit is told to shrink its own payload or batch.

local limits = {}

local KIB = 1024

limits.MODEM_FRAME_BYTES = 16 * KIB
limits.MODEM_PAYLOAD_BYTES = 8 * KIB
limits.GATEWAY_FRAME_BYTES = 256 * KIB
limits.TRAFFIC_BATCH_BYTES = 128 * KIB
limits.TRAFFIC_BATCH_EVENTS = 100
limits.TOPOLOGY_ENTITIES = 2000

limits.STRING_BYTES = 8 * KIB
limits.DEPTH = 16
limits.OBJECT_KEYS = 128
limits.ARRAY_ELEMENTS = 2000

limits.RELATIONSHIP_IN_FLIGHT = 64
limits.GATEWAY_IN_FLIGHT = 256

limits.ACCESS_TOKEN_SECONDS = 120

-- resolve produces the per-decode structural bounds, letting a caller narrow
-- them but never widen them.
function limits.resolve(options)
  options = options or {}
  local function bounded(candidate, ceiling)
    if candidate == nil then return ceiling end
    assert(type(candidate) == "number" and candidate >= 1 and candidate <= ceiling,
      "structural limits may be narrowed but never widened")
    return candidate
  end
  return {
    stringBytes = bounded(options.stringBytes, limits.STRING_BYTES),
    depth = bounded(options.depth, limits.DEPTH),
    objectKeys = bounded(options.objectKeys, limits.OBJECT_KEYS),
    arrayElements = bounded(options.arrayElements, limits.ARRAY_ELEMENTS),
  }
end

return limits
