package protocol

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"unicode"
	"unicode/utf8"
)

// DecodeDeliveryRequest strictly decodes and validates one delivery request.
func DecodeDeliveryRequest(body []byte) (*DeliveryRequest, error) {
	if len(body) == 0 || len(body) > MaxHTTPBodyBytes {
		return nil, errors.New("invalid delivery request size")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var request DeliveryRequest
	if err := decoder.Decode(&request); err != nil {
		return nil, fmt.Errorf("invalid delivery request: %w", err)
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return nil, err
	}
	if err := ValidateDeliveryRequest(&request); err != nil {
		return nil, err
	}
	return &request, nil
}

// ValidateDeliveryRequest enforces the V1 identity and text bounds, including
// the smaller interim-message bound.
func ValidateDeliveryRequest(request *DeliveryRequest) error {
	if request == nil {
		return errors.New("delivery request is required")
	}
	if request.ProtocolVersion != Version {
		return fmt.Errorf("unsupported protocolVersion %q", request.ProtocolVersion)
	}
	for name, value := range map[string]string{
		"deliveryId": request.DeliveryID, "idempotencyId": request.IdempotencyID,
		"originatingEventId": request.OriginatingEvent, "accountId": request.AccountID,
		"contextId": request.ContextID, "replyTarget": request.ReplyTarget,
	} {
		if err := validateRequiredIdentity(name, value); err != nil {
			return err
		}
	}
	if err := validateOptionalIdentity("threadId", request.ThreadID); err != nil {
		return err
	}
	limit := MaxTextBytes
	switch request.Kind {
	case DeliveryKindMessage:
		limit = MaxInterimTextBytes
	case DeliveryKindFinal, DeliveryKindError:
	default:
		return fmt.Errorf("unsupported delivery kind %q", request.Kind)
	}
	if request.Text == "" || len(request.Text) > limit || !utf8.ValidString(request.Text) || containsUnsafeControl(request.Text, true) {
		return errors.New("delivery text is invalid")
	}
	return nil
}

// ValidateEvent applies the controller's V1 event checks before ingress so a
// malformed mapping fails locally instead of being retried against Orka.
func ValidateEvent(event *EventEnvelope) error {
	if event == nil {
		return errors.New("event is required")
	}
	if event.ProtocolVersion != Version || event.EventType != EventTypeText {
		return errors.New("unsupported event version or type")
	}
	for name, value := range map[string]string{
		"externalEventId": event.ExternalEventID, "accountId": event.AccountID,
		"contextId": event.ContextID, "sender.id": event.Sender.ID,
	} {
		if err := validateRequiredIdentity(name, value); err != nil {
			return err
		}
	}
	for name, value := range map[string]string{
		"threadId": event.ThreadID, "sender.displayName": event.Sender.DisplayName, "replyTarget": event.ReplyTarget,
	} {
		if err := validateOptionalIdentity(name, value); err != nil {
			return err
		}
	}
	if event.Text == "" || len(event.Text) > MaxTextBytes || !utf8.ValidString(event.Text) || containsUnsafeControl(event.Text, true) {
		return errors.New("event text is invalid")
	}
	if len(event.Metadata) > 0 {
		return errors.New("event metadata is not supported")
	}
	return nil
}

// ValidateIngressResponse checks Orka's durable admission acknowledgement.
func ValidateIngressResponse(response *IngressResponse) error {
	if response == nil {
		return errors.New("ingress response is required")
	}
	switch response.Status {
	case IngressStatusAccepted, IngressStatusDuplicate, IngressStatusRejected, IngressStatusDeadLettered:
	default:
		return fmt.Errorf("unsupported ingress status %q", response.Status)
	}
	if err := validateRequiredIdentity("eventId", response.EventID); err != nil {
		return err
	}
	if response.State == "" || len(response.State) > 64 || containsUnsafeControl(response.State, false) {
		return errors.New("ingress state is invalid")
	}
	if len(response.Message) > 1024 || !utf8.ValidString(response.Message) || containsUnsafeControl(response.Message, true) {
		return errors.New("ingress message is invalid")
	}
	return nil
}

// ValidIdentity reports whether value is a safe non-empty V1 identity.
func ValidIdentity(value string) bool {
	return validateRequiredIdentity("identity", value) == nil
}

func ConstantTimeBearerEqual(got, want string) bool {
	got = strings.TrimSpace(got)
	want = strings.TrimSpace(want)
	if got == "" || want == "" || len(got) != len(want) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

func BearerToken(header string) string {
	parts := strings.Fields(header)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return ""
	}
	return parts[1]
}

// SanitizeMessage strips controls and bounds adapter-owned messages.
func SanitizeMessage(message string, limit int) string {
	message = strings.TrimSpace(message)
	message = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\n' && r != '\t' {
			return -1
		}
		return r
	}, message)
	if limit > 0 && len(message) > limit {
		message = message[:limit]
		for !utf8.ValidString(message) && len(message) > 0 {
			message = message[:len(message)-1]
		}
	}
	return message
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); err == io.EOF {
		return nil
	} else if err != nil {
		return fmt.Errorf("invalid trailing JSON: %w", err)
	}
	return errors.New("request must contain exactly one JSON value")
}

func validateRequiredIdentity(name, value string) error {
	if value == "" {
		return fmt.Errorf("%s is required", name)
	}
	return validateOptionalIdentity(name, value)
}

func validateOptionalIdentity(name, value string) error {
	if value == "" {
		return nil
	}
	if value != strings.TrimSpace(value) || len(value) > MaxIdentityBytes || !utf8.ValidString(value) || containsUnsafeControl(value, false) {
		return fmt.Errorf("%s is invalid", name)
	}
	return nil
}

func containsUnsafeControl(value string, allowNewlines bool) bool {
	return strings.ContainsFunc(value, func(r rune) bool {
		if !unicode.IsControl(r) {
			return false
		}
		return !(allowNewlines && (r == '\n' || r == '\r' || r == '\t'))
	})
}
