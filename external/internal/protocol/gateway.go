package protocol

// Gateway framing.
//
// The Central Server opens one outbound WebSocket per World and presents its
// Gateway Credential in the Authorization header. Frames afterwards rely on WSS
// plus the authenticated Gateway Session rather than a second message HMAC, so
// this layer validates structure, version, limits, and correlation only.

var gatewayHelloShape = shape{
	required: map[string]string{
		"v": "integer", "world_id": "id", "central_id": "id",
		"last_topology_revision": "revision", "last_traffic_sequence": "non_negative",
	},
}

var gatewayWelcomeShape = shape{
	required: map[string]string{
		"v": "integer", "gateway_session_id": "id",
		"accepted_topology_revision": "revision", "accepted_traffic_sequence": "non_negative",
		"server_time": "timestamp",
	},
}

var gatewayFrameShape = shape{
	required: map[string]string{"v": "integer", "kind": "operation_name", "body": "object"},
	optional: map[string]string{"request_id": "id", "command_id": "id"},
}

// GatewayHello is the Central Server's opening frame.
type GatewayHello struct {
	WorldID              string
	CentralID            string
	LastTopologyRevision int64
	LastTrafficSequence  int64
}

// Object renders the hello frame.
func (h GatewayHello) Object() Object {
	return Object{
		"v": Version, "world_id": h.WorldID, "central_id": h.CentralID,
		"last_topology_revision": h.LastTopologyRevision,
		"last_traffic_sequence":  h.LastTrafficSequence,
	}
}

// GatewayWelcome is the External Application's reply that opens a Gateway
// Session for one World.
type GatewayWelcome struct {
	GatewaySessionID         string
	AcceptedTopologyRevision int64
	AcceptedTrafficSequence  int64
	ServerTime               string
}

// Object renders the welcome frame.
func (w GatewayWelcome) Object() Object {
	return Object{
		"v": Version, "gateway_session_id": w.GatewaySessionID,
		"accepted_topology_revision": w.AcceptedTopologyRevision,
		"accepted_traffic_sequence":  w.AcceptedTrafficSequence,
		"server_time":                w.ServerTime,
	}
}

// GatewayFrame is one validated Gateway message.
type GatewayFrame struct {
	Kind      string
	RequestID string
	CommandID string
	Body      Object
}

func decodeGatewayObject(text string) (Object, error) {
	if len(text) > GatewayFrameBytes {
		return nil, newError(CodeMessageTooLarge, "gateway message exceeds %d bytes", GatewayFrameBytes)
	}
	value, err := Decode(text, DefaultLimits())
	if err != nil {
		return nil, err
	}
	object, ok := value.(Object)
	if !ok {
		return nil, newError(CodeInvalidMessage, "gateway message must be an object")
	}
	return object, nil
}

func checkGatewayVersion(object Object, what string) error {
	if version, _ := integerValue(object["v"]); version != Version {
		return newError(CodeUnsupportedVersion, "%s declares version %v", what, object["v"])
	}
	return nil
}

// EncodeGatewayHello renders the opening frame.
func EncodeGatewayHello(hello GatewayHello) (string, error) {
	object := hello.Object()
	if err := validateShape(gatewayHelloShape, object, "gateway_hello"); err != nil {
		return "", err
	}
	return Encode(object)
}

// DecodeGatewayHello validates the opening frame.
func DecodeGatewayHello(text string) (*GatewayHello, error) {
	object, err := decodeGatewayObject(text)
	if err != nil {
		return nil, err
	}
	if err := validateShape(gatewayHelloShape, object, "gateway_hello"); err != nil {
		return nil, err
	}
	if err := checkGatewayVersion(object, "gateway_hello"); err != nil {
		return nil, err
	}
	worldID, _ := stringValue(object["world_id"])
	centralID, _ := stringValue(object["central_id"])
	topology, _ := integerValue(object["last_topology_revision"])
	traffic, _ := integerValue(object["last_traffic_sequence"])
	return &GatewayHello{
		WorldID: worldID, CentralID: centralID,
		LastTopologyRevision: topology, LastTrafficSequence: traffic,
	}, nil
}

// EncodeGatewayWelcome renders the accepting reply.
func EncodeGatewayWelcome(welcome GatewayWelcome) (string, error) {
	object := welcome.Object()
	if err := validateShape(gatewayWelcomeShape, object, "gateway_welcome"); err != nil {
		return "", err
	}
	return Encode(object)
}

// DecodeGatewayWelcome validates the accepting reply.
func DecodeGatewayWelcome(text string) (*GatewayWelcome, error) {
	object, err := decodeGatewayObject(text)
	if err != nil {
		return nil, err
	}
	if err := validateShape(gatewayWelcomeShape, object, "gateway_welcome"); err != nil {
		return nil, err
	}
	if err := checkGatewayVersion(object, "gateway_welcome"); err != nil {
		return nil, err
	}
	sessionID, _ := stringValue(object["gateway_session_id"])
	topology, _ := integerValue(object["accepted_topology_revision"])
	traffic, _ := integerValue(object["accepted_traffic_sequence"])
	serverTime, _ := stringValue(object["server_time"])
	return &GatewayWelcome{
		GatewaySessionID: sessionID, AcceptedTopologyRevision: topology,
		AcceptedTrafficSequence: traffic, ServerTime: serverTime,
	}, nil
}

// EncodeGatewayFrame renders one Gateway message.
func EncodeGatewayFrame(frame GatewayFrame) (string, error) {
	if !Allows(TransportGateway, frame.Kind) {
		return "", newError(CodeInvalidMessage, "kind %q is not carried by the Gateway", frame.Kind)
	}
	if err := ValidateBody(frame.Kind, frame.Body); err != nil {
		return "", err
	}
	object := Object{"v": Version, "kind": frame.Kind, "body": frame.Body}
	if frame.RequestID != "" {
		object["request_id"] = frame.RequestID
	}
	if frame.CommandID != "" {
		object["command_id"] = frame.CommandID
	}
	if err := validateShape(gatewayFrameShape, object, "gateway_frame"); err != nil {
		return "", err
	}
	text, err := Encode(object)
	if err != nil {
		return "", err
	}
	if err := checkGatewayFrameSize(frame.Kind, text); err != nil {
		return "", err
	}
	return text, nil
}

// DecodeGatewayFrame validates one Gateway message.
func DecodeGatewayFrame(text string) (*GatewayFrame, error) {
	object, err := decodeGatewayObject(text)
	if err != nil {
		return nil, err
	}
	if err := validateShape(gatewayFrameShape, object, "gateway_frame"); err != nil {
		return nil, err
	}
	if err := checkGatewayVersion(object, "gateway_frame"); err != nil {
		return nil, err
	}
	kind, _ := stringValue(object["kind"])
	if !Allows(TransportGateway, kind) {
		return nil, newError(CodeInvalidMessage, "kind %q is not carried by the Gateway", kind)
	}
	if err := checkGatewayFrameSize(kind, text); err != nil {
		return nil, err
	}
	body, _ := object["body"].(Object)
	if err := ValidateBody(kind, body); err != nil {
		return nil, err
	}
	requestID, _ := stringValue(object["request_id"])
	commandID, _ := stringValue(object["command_id"])
	return &GatewayFrame{Kind: kind, RequestID: requestID, CommandID: commandID, Body: body}, nil
}

// checkGatewayFrameSize applies the narrower batch ceiling on top of the
// Gateway message limit. CraftNet performs no fragmentation: an oversized batch
// must be split by its sender.
func checkGatewayFrameSize(kind, text string) error {
	if kind == "traffic_batch" && len(text) > TrafficBatchBytes {
		return newError(CodeMessageTooLarge, "traffic batch exceeds %d bytes", TrafficBatchBytes)
	}
	if len(text) > GatewayFrameBytes {
		return newError(CodeMessageTooLarge, "gateway message exceeds %d bytes", GatewayFrameBytes)
	}
	return nil
}
