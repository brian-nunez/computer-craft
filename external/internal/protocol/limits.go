package protocol

// CraftNet v1 wire limits. Every bound the protocol states lives here so that a
// decoder, a frame writer, and a test all read the same number. CraftNet
// performs no fragmentation: a caller that exceeds a limit is told to shrink its
// own payload or batch.
const (
	kib = 1024

	ModemFrameBytes   = 16 * kib
	ModemPayloadBytes = 8 * kib
	GatewayFrameBytes = 256 * kib

	TrafficBatchBytes  = 128 * kib
	TrafficBatchEvents = 100
	TopologyEntities   = 2000

	StringBytes   = 8 * kib
	Depth         = 16
	ObjectKeys    = 128
	ArrayElements = 2000

	RelationshipInFlight = 64
	GatewayInFlight      = 256

	AccessTokenSeconds = 120
)

// StructuralLimits bounds one decode. A caller may narrow a limit but never
// widen it past the wire maximum.
type StructuralLimits struct {
	StringBytes   int
	Depth         int
	ObjectKeys    int
	ArrayElements int
}

// DefaultLimits returns the full v1 structural bounds.
func DefaultLimits() StructuralLimits {
	return StructuralLimits{
		StringBytes:   StringBytes,
		Depth:         Depth,
		ObjectKeys:    ObjectKeys,
		ArrayElements: ArrayElements,
	}
}

func (l StructuralLimits) resolve() StructuralLimits {
	defaults := DefaultLimits()
	if l.StringBytes <= 0 || l.StringBytes > defaults.StringBytes {
		l.StringBytes = defaults.StringBytes
	}
	if l.Depth <= 0 || l.Depth > defaults.Depth {
		l.Depth = defaults.Depth
	}
	if l.ObjectKeys <= 0 || l.ObjectKeys > defaults.ObjectKeys {
		l.ObjectKeys = defaults.ObjectKeys
	}
	if l.ArrayElements <= 0 || l.ArrayElements > defaults.ArrayElements {
		l.ArrayElements = defaults.ArrayElements
	}
	return l
}
