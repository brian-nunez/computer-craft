package gateway

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/operations"
	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
)

//--------------------------------------------------------------------------
// Ingestion
//--------------------------------------------------------------------------

// ingestTopology records what the Central Server reports about its World. The
// projection is a view of authoritative in-world state, never an authority: it
// is stored as received and never edited here.
func (s *Session) ingestTopology(ctx context.Context, frame *protocol.GatewayFrame) error {
	revision, _ := frame.Body["revision"].(int64)
	document, err := protocol.Encode(frame.Body)
	if err != nil {
		return err
	}

	err = s.registry.backing.Do(ctx, func(tx store.Tx) error {
		return tx.PutTopology(store.Topology{
			WorldID:    s.WorldID,
			Revision:   revision,
			Document:   document,
			ObservedAt: s.registry.now().UTC(),
		})
	})
	if err != nil {
		s.sendError(ctx, frame.RequestID, protocol.CodeInternalError, "topology was not stored")
		return nil
	}
	return s.acknowledge(ctx, frame, revision)
}

// ingestTraffic stores a batch of Traffic Events. A reconnecting Central Server
// replays its buffer, so an event already held is not an error -- and a gap in
// the sequence is left visible rather than filled in.
func (s *Session) ingestTraffic(ctx context.Context, frame *protocol.GatewayFrame) error {
	first, _ := frame.Body["first_sequence"].(int64)
	last, _ := frame.Body["last_sequence"].(int64)
	list, _ := frame.Body["events"].(protocol.Array)

	events := make([]store.Event, 0, len(list))
	for index, raw := range list {
		event, ok := raw.(protocol.Object)
		if !ok {
			continue
		}
		document, err := protocol.Encode(event)
		if err != nil {
			return err
		}
		eventID, _ := event["event_id"].(string)
		observed, _ := event["observed_at_ms"].(int64)
		events = append(events, store.Event{
			WorldID:  s.WorldID,
			Sequence: first + int64(index),
			EventID:  eventID,
			// The Computer's clock is never trusted for anything but ordering,
			// so what is recorded is when this application received it.
			ObservedAt: s.registry.now().UTC(),
			Document:   document,
		})
		_ = observed
	}

	err := s.registry.backing.Do(ctx, func(tx store.Tx) error {
		held, err := tx.LastSequence(s.WorldID)
		if err != nil {
			return err
		}
		if first > held+1 {
			// A gap. It is recorded as an audit note rather than hidden, and the
			// events are still stored: what was lost stays lost and visible.
			if err := tx.AppendAudit(store.AuditRecord{
				WorldID: s.WorldID, Actor: s.CentralID, Action: "traffic.gap",
				Subject:  fmt.Sprintf("%d..%d", held+1, first-1),
				Detail:   "Traffic Events were lost while the Gateway was away",
				Recorded: s.registry.now().UTC(),
			}); err != nil {
				return err
			}
		}
		return tx.AppendEvents(events)
	})
	if err != nil {
		s.sendError(ctx, frame.RequestID, protocol.CodeInternalError, "traffic was not stored")
		return nil
	}

	s.mutex.Lock()
	if last > s.sequence {
		s.sequence = last
	}
	s.mutex.Unlock()
	return s.acknowledge(ctx, frame, last)
}

func (s *Session) acknowledge(ctx context.Context, frame *protocol.GatewayFrame, revision int64) error {
	if frame.RequestID == "" {
		return nil
	}
	return s.send(ctx, protocol.GatewayFrame{
		Kind:      "ack",
		RequestID: frame.RequestID,
		Body: protocol.Object{
			"acked_request_id": frame.RequestID,
			"result_revision":  revision,
		},
	})
}

//--------------------------------------------------------------------------
// External Operations
//--------------------------------------------------------------------------

func ancestryOf(body protocol.Object) store.Ancestry {
	raw, _ := body["ancestry"].(protocol.Object)
	text := func(key string) string {
		value, _ := raw[key].(string)
		return value
	}
	return store.Ancestry{
		WorldID:           text("world_id"),
		ISPID:             text("isp_id"),
		CustomerNetworkID: text("customer_network_id"),
		RouterID:          text("router_id"),
		ComputerID:        text("computer_id"),
		LocalAddress:      text("local_address"),
	}
}

// serveExternalRequest is the whole external path: check who is asking against
// what they are asking for, run the handler, answer. Nothing here trusts a
// field in the request over the session it arrived on.
func (s *Session) serveExternalRequest(ctx context.Context, frame *protocol.GatewayFrame) error {
	operation, _ := frame.Body["operation"].(string)
	payload, _ := frame.Body["payload"].(protocol.Object)
	ancestry := ancestryOf(frame.Body)

	// The session says which World this is. A request claiming another one is
	// refused however well formed it looks.
	if ancestry.WorldID != s.WorldID {
		return s.refuse(ctx, frame, protocol.CodeAuthenticationFail,
			"that ancestry belongs to another World")
	}

	policy, allowed := s.registry.allowlist.Policy(operation)
	if !allowed {
		return s.refuse(ctx, frame, protocol.CodeForbiddenOperation,
			fmt.Sprintf("%q is not an allowed operation", operation))
	}

	call := operations.Call{
		Operation: operation,
		Ancestry:  ancestry,
		Payload:   payload,
	}

	switch policy.Credential {
	case operations.CredentialAncestry:
		// device.register carries no secret: the verified ancestry is the
		// attestation, which is the whole reason it is the one exception.

	case operations.CredentialDevice:
		presented, _ := frame.Body["device_credential"].(string)
		device, err := s.registry.identities.AuthenticateDevice(ctx, s.registry.backing, ancestry, presented)
		if err != nil {
			return s.refuseError(ctx, frame, err)
		}
		call.Device = &device

	case operations.CredentialAccessToken:
		presented, _ := frame.Body["access_token"].(string)
		claims, err := s.registry.identities.AuthorizeToken(ctx, s.registry.backing, presented, operation, ancestry)
		if err != nil {
			return s.refuseError(ctx, frame, err)
		}
		call.Claims = claims
	}

	result, err := s.registry.allowlist.Execute(ctx, call)
	if err != nil {
		return s.refuseError(ctx, frame, err)
	}
	if result.Payload == nil {
		result.Payload = protocol.Object{}
	}

	return s.send(ctx, protocol.GatewayFrame{
		Kind:      "external_response",
		RequestID: frame.RequestID,
		Body:      protocol.Object{"payload": result.Payload},
	})
}

func (s *Session) refuse(ctx context.Context, frame *protocol.GatewayFrame, code, message string) error {
	body, err := protocol.ErrorBody(code, message, nil)
	if err != nil {
		return err
	}
	return s.send(ctx, protocol.GatewayFrame{
		Kind: "error", RequestID: frame.RequestID, Body: body,
	})
}

func (s *Session) refuseError(ctx context.Context, frame *protocol.GatewayFrame, cause error) error {
	code := protocol.CodeOf(cause)
	if code == "" {
		code = protocol.CodeInternalError
	}
	message := cause.Error()
	var typed *protocol.Error
	if errors.As(cause, &typed) {
		message = typed.Message
	} else {
		// An unexpected failure is reported without exposing internals.
		message = "the operation could not be completed"
	}
	return s.refuse(ctx, frame, code, message)
}

//--------------------------------------------------------------------------
// Administrative commands
//--------------------------------------------------------------------------

// Command sends an administrative instruction and waits for its result. It is
// idempotent by Command ID: sending the same one twice returns the result that
// was already applied rather than applying it again.
func (r *Registry) Command(ctx context.Context, worldID, commandID, action string, body protocol.Object, wait time.Duration) (store.Command, error) {
	var existing store.Command
	err := r.backing.Do(ctx, func(tx store.Tx) error {
		found, err := tx.Command(commandID)
		if err == nil {
			existing = found
			return nil
		}
		if !errors.Is(err, store.ErrNotFound) {
			return err
		}
		document, err := protocol.Encode(body)
		if err != nil {
			return err
		}
		record := store.Command{
			CommandID: commandID, WorldID: worldID, Action: action,
			Document: document, Status: store.CommandPending,
			IssuedAt: r.now().UTC(),
		}
		existing = record
		return tx.PutCommand(record)
	})
	if err != nil {
		return store.Command{}, err
	}
	if existing.Status != store.CommandPending {
		// Already settled. The caller gets what happened, not a second attempt.
		return existing, nil
	}

	session, ok := r.Session(worldID)
	if !ok {
		// Retained as pending: it is resent when the Gateway comes back.
		return existing, ErrNoSession
	}
	return session.deliverCommand(ctx, existing, body, wait)
}

func (s *Session) deliverCommand(ctx context.Context, record store.Command, body protocol.Object, wait time.Duration) (store.Command, error) {
	waiting := make(chan protocol.Object, 1)
	s.mutex.Lock()
	if s.closed {
		s.mutex.Unlock()
		return record, ErrNoSession
	}
	if len(s.pending) >= s.registry.inFlight {
		s.mutex.Unlock()
		return record, &protocol.Error{
			Code:    protocol.CodeBusy,
			Message: "this Gateway Session has no capacity left",
		}
	}
	s.pending[record.CommandID] = waiting
	s.mutex.Unlock()

	err := s.send(ctx, protocol.GatewayFrame{
		Kind: "admin_command", CommandID: record.CommandID, RequestID: record.CommandID, Body: body,
	})
	if err != nil {
		s.mutex.Lock()
		delete(s.pending, record.CommandID)
		s.mutex.Unlock()
		return record, err
	}
	if wait <= 0 {
		return record, nil
	}

	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-waiting:
		return s.reloadCommand(ctx, record.CommandID)
	case <-timer.C:
		s.mutex.Lock()
		delete(s.pending, record.CommandID)
		s.mutex.Unlock()
		// Still pending, and still retained: an idempotent command is the one
		// thing CraftNet does resend.
		return record, &protocol.Error{
			Code:    protocol.CodeRequestTimeout,
			Message: "the Central Server did not report a result",
		}
	case <-ctx.Done():
		return record, ctx.Err()
	}
}

func (s *Session) reloadCommand(ctx context.Context, commandID string) (store.Command, error) {
	var record store.Command
	err := s.registry.backing.Do(ctx, func(tx store.Tx) error {
		found, err := tx.Command(commandID)
		if err != nil {
			return err
		}
		record = found
		return nil
	})
	return record, err
}

// settleCommand records what the Central Server did with an instruction. The
// Central Server is authoritative: this stores its answer and stops resending.
func (s *Session) settleCommand(ctx context.Context, frame *protocol.GatewayFrame) error {
	commandID, _ := frame.Body["command_id"].(string)
	status, _ := frame.Body["status"].(string)
	revision, _ := frame.Body["revision"].(int64)
	failure := ""
	if problem, ok := frame.Body["error"].(protocol.Object); ok {
		if code, ok := problem["code"].(string); ok {
			failure = code
		}
	}

	settled := s.registry.now().UTC()
	err := s.registry.backing.Do(ctx, func(tx store.Tx) error {
		record, err := tx.Command(commandID)
		if err != nil {
			return err
		}
		record.Status = status
		record.Revision = revision
		record.Error = failure
		record.SettledAt = &settled
		if err := tx.PutCommand(record); err != nil {
			return err
		}
		return tx.AppendAudit(store.AuditRecord{
			WorldID: s.WorldID, Actor: s.CentralID, Action: "command." + status,
			Subject: commandID, Detail: record.Action, Recorded: settled,
		})
	})
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return err
	}

	// Whoever is waiting hears about it either way.
	s.mutex.Lock()
	channel, ok := s.pending[commandID]
	if ok {
		delete(s.pending, commandID)
	}
	s.mutex.Unlock()
	if ok {
		channel <- frame.Body
		close(channel)
	}
	return nil
}

// resendPending replays every unsettled command onto a session that has just
// been established. The Command ID is unchanged, so a Central Server that
// already applied one returns the result it already has.
func (s *Session) resendPending(ctx context.Context) error {
	var pending []store.Command
	err := s.registry.backing.Do(ctx, func(tx store.Tx) error {
		found, err := tx.PendingCommands(s.WorldID)
		if err != nil {
			return err
		}
		pending = found
		return nil
	})
	if err != nil {
		return err
	}

	for _, command := range pending {
		value, err := protocol.Decode(command.Document, protocol.DefaultLimits())
		if err != nil {
			continue
		}
		body, ok := value.(protocol.Object)
		if !ok {
			continue
		}
		if err := s.send(ctx, protocol.GatewayFrame{
			Kind: "admin_command", CommandID: command.CommandID,
			RequestID: command.CommandID, Body: body,
		}); err != nil {
			return err
		}
	}
	return nil
}
