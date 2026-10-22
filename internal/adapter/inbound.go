package adapter

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode"

	"github.com/orka-agents/orka-gateway-imessage/internal/imessage"
	"github.com/orka-agents/orka-gateway-imessage/internal/imsg"
	"github.com/orka-agents/orka-gateway-imessage/internal/protocol"
	"github.com/orka-agents/orka-gateway-imessage/internal/store"
)

const (
	// echoWindow is how close in time an outbound send and an identical
	// inbound row in the same chat must be for the row to count as the
	// send's echo (the received copy in a self-chat).
	echoWindow = 2 * time.Minute
	// maxMessageAge matches Orka's event expiry. Older rows are never
	// forwarded, which also bounds any replay after a cursor reset.
	maxMessageAge  = 24 * time.Hour
	maxBackoff     = 30 * time.Second
	stableWatchRun = time.Minute
)

// RunInbound watches Messages and forwards allowlisted text to Orka until ctx
// ends. It resumes from the durable cursor after every interruption, so a
// message is never skipped; Orka deduplicates replays by message GUID.
func (s *Server) RunInbound(ctx context.Context) {
	var backoff time.Duration
	for ctx.Err() == nil {
		started := time.Now()
		err := s.watchOnce(ctx)
		if ctx.Err() != nil {
			return
		}
		if time.Since(started) > stableWatchRun {
			backoff = 0
		}
		backoff = nextBackoff(backoff)
		s.logger.Warn("iMessage watch ended; resubscribing", "error", safeError(err), "retry_in", backoff.String())
		if !sleep(ctx, backoff) {
			return
		}
	}
}

func (s *Server) watchOnce(ctx context.Context) error {
	cursor, initialized, err := s.store.Cursor(ctx)
	if err != nil {
		return fmt.Errorf("read watch cursor: %w", err)
	}
	if !initialized {
		// First start: begin after the newest existing row and persist that
		// position, so history is never forwarded and a restart resumes here.
		latest, err := s.imessage.LatestRowID(ctx)
		if err != nil {
			return fmt.Errorf("find the newest Messages row: %w", err)
		}
		if err := s.store.InitializeCursor(ctx, latest); err != nil {
			return fmt.Errorf("initialize watch cursor: %w", err)
		}
		if cursor, _, err = s.store.Cursor(ctx); err != nil {
			return fmt.Errorf("read watch cursor: %w", err)
		}
	}
	since := cursor
	if since == 0 {
		// The database had no rows when the cursor was initialized.
		since = -1
	}
	stream, err := s.imessage.Subscribe(ctx, since)
	if err != nil {
		return fmt.Errorf("subscribe to Messages: %w", err)
	}
	defer stream.Close()
	s.logger.Info("watching iMessage", "since_rowid", cursor)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case message, ok := <-stream.Messages():
			if !ok {
				return stream.Err()
			}
			if err := s.handleInbound(ctx, message); err != nil {
				return err
			}
		}
	}
}

// handleInbound forwards or skips one watch notification and then advances
// the cursor. It returns an error only when the cursor must not advance.
func (s *Server) handleInbound(ctx context.Context, message imsg.Message) error {
	if message.Type != "" || message.ID <= 0 {
		// Edits and unsends reuse an earlier row and never advance the cursor.
		return nil
	}
	event, skip, err := s.mapMessage(ctx, message)
	if err != nil {
		return err
	}
	if skip != "" {
		s.logger.Debug("skipping iMessage", "rowid", message.ID, "reason", skip)
		return s.store.AdvanceCursor(ctx, message.ID)
	}
	// Record the chat before Orka can reply to it.
	if err := s.store.RememberReplyChat(ctx, event.ReplyTarget); err != nil {
		return fmt.Errorf("record reply chat: %w", err)
	}
	var backoff time.Duration
	for {
		ingress, err := s.admit(ctx, event)
		if err == nil {
			s.logger.Info("forwarded iMessage to Orka", "rowid", message.ID, "event_id", ingress.EventID, "status", ingress.Status)
			break
		}
		var permanent permanentIngressError
		if errors.As(err, &permanent) {
			s.logger.Error("Orka rejected iMessage event; skipping it", "rowid", message.ID, "error", safeError(err))
			break
		}
		backoff = nextBackoff(backoff)
		s.logger.Warn("Orka ingress unavailable; retrying", "rowid", message.ID, "error", safeError(err), "retry_in", backoff.String())
		if !sleep(ctx, backoff) {
			return ctx.Err()
		}
	}
	return s.store.AdvanceCursor(ctx, message.ID)
}

// mapMessage converts a Messages row into an Orka event, or returns a skip
// reason. Only text from allowlisted senders in allowed chats is forwarded.
func (s *Server) mapMessage(ctx context.Context, message imsg.Message) (*protocol.EventEnvelope, string, error) {
	switch {
	case message.IsFromMe:
		return nil, "sent by this account", nil
	case message.IsReaction:
		return nil, "reaction", nil
	case len(message.Poll) > 0 && string(message.Poll) != "null":
		return nil, "poll", nil
	}
	chat, err := imessage.ParseChatGUID(message.ChatGUID)
	if err != nil {
		return nil, "unsupported chat", nil
	}
	if chat.Group {
		return nil, "group chat", nil
	}
	if !s.chatAllowed(chat) {
		return nil, "chat is not allowlisted", nil
	}
	sender, err := imessage.NormalizeHandle(message.Sender)
	if err != nil || !s.config.Allowlist.Contains(sender) {
		return nil, "sender is not allowlisted", nil
	}
	text := cleanText(message.Text)
	switch {
	case text == "":
		return nil, "no text", nil
	case len(text) > protocol.MaxTextBytes:
		return nil, "text is too long", nil
	case !protocol.ValidIdentity(message.GUID):
		return nil, "invalid message GUID", nil
	}
	created, err := time.Parse(time.RFC3339Nano, message.CreatedAt)
	hasCreated := err == nil
	if hasCreated && time.Since(created) > maxMessageAge {
		return nil, "older than the event expiry", nil
	}
	// Match echoes against the row's own time so a late-processed echo
	// still matches its send.
	reference := time.Now()
	if hasCreated {
		reference = created
	}
	echo, err := s.store.SentNear(ctx, chat.GUID, store.TextDigest(text), reference, echoWindow)
	if err != nil {
		return nil, "", fmt.Errorf("check outbound echo: %w", err)
	}
	if echo {
		return nil, "echo of an adapter send", nil
	}
	event := &protocol.EventEnvelope{
		ProtocolVersion: protocol.Version,
		ExternalEventID: message.GUID,
		EventType:       protocol.EventTypeText,
		AccountID:       s.config.AccountID,
		ContextID:       chat.GUID,
		Sender:          protocol.Sender{ID: sender},
		Text:            text,
		ReplyTarget:     chat.GUID,
	}
	if name := strings.TrimSpace(message.SenderName); protocol.ValidIdentity(name) {
		event.Sender.DisplayName = name
	}
	if hasCreated {
		occurred := created.UTC()
		event.OccurredAt = &occurred
	}
	if err := protocol.ValidateEvent(event); err != nil {
		return nil, "invalid event", nil
	}
	return event, "", nil
}

// cleanText drops attachment placeholders and controls Orka rejects.
func cleanText(text string) string {
	return strings.TrimSpace(strings.Map(func(r rune) rune {
		if r == '￼' || (unicode.IsControl(r) && r != '\n' && r != '\r' && r != '\t') {
			return -1
		}
		return r
	}, text))
}

type permanentIngressError struct{ status int }

func (e permanentIngressError) Error() string {
	return fmt.Sprintf("orka ingress returned HTTP %d", e.status)
}

func (s *Server) admit(ctx context.Context, event *protocol.EventEnvelope) (*protocol.IngressResponse, error) {
	body, err := json.Marshal(event)
	if err != nil {
		return nil, permanentIngressError{status: 0}
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, s.config.IngressURL, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+s.config.IngressBearerToken)
	request.Header.Set("Content-Type", "application/json")
	response, err := s.client.Do(request)
	if err != nil {
		return nil, errors.New("orka ingress request failed")
	}
	defer response.Body.Close() //nolint:errcheck
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, protocol.MaxAdapterResponseBytes+1))
	if err != nil || len(responseBody) > protocol.MaxAdapterResponseBytes {
		return nil, errors.New("orka ingress response was invalid")
	}
	switch response.StatusCode {
	case http.StatusAccepted:
	case http.StatusBadRequest, http.StatusRequestEntityTooLarge, http.StatusUnprocessableEntity:
		return nil, permanentIngressError{status: response.StatusCode}
	default:
		return nil, fmt.Errorf("orka ingress returned HTTP %d", response.StatusCode)
	}
	// HTTP 202 is Orka's durable admission. An acknowledgement body this
	// adapter cannot validate must not cause a resend loop.
	var ingress protocol.IngressResponse
	if err := json.Unmarshal(responseBody, &ingress); err != nil || protocol.ValidateIngressResponse(&ingress) != nil {
		s.logger.Warn("Orka admitted an iMessage event with an unrecognized acknowledgement")
		return &protocol.IngressResponse{Status: "unrecognized"}, nil
	}
	return &ingress, nil
}

func nextBackoff(current time.Duration) time.Duration {
	if current <= 0 {
		return time.Second
	}
	return min(2*current, maxBackoff)
}

func sleep(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
