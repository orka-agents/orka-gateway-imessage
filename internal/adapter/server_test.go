package adapter

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/orka-agents/orka-gateway-imessage/internal/imessage"
	"github.com/orka-agents/orka-gateway-imessage/internal/imsg"
	"github.com/orka-agents/orka-gateway-imessage/internal/protocol"
	"github.com/orka-agents/orka-gateway-imessage/internal/store"
)

const (
	testAccount  = "mac-messages"
	testHandle   = "+14155551212"
	testChat     = "iMessage;-;+14155551212"
	testOutbound = "outbound-token"
)

type fakeSend struct{ chat, text string }

type fakeIMessage struct {
	mu      sync.Mutex
	sends   []fakeSend
	results []func() (imsg.SendResult, error)
	since   []int64
	streams chan *fakeStream
	latest  int64
	latests int
}

func (f *fakeIMessage) LatestRowID(context.Context) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.latests++
	return f.latest, nil
}

func (f *fakeIMessage) Send(_ context.Context, chat, text string) (imsg.SendResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sends = append(f.sends, fakeSend{chat, text})
	if len(f.results) > 0 {
		next := f.results[0]
		f.results = f.results[1:]
		return next()
	}
	return imsg.SendResult{OK: true, GUID: fmt.Sprintf("GUID-%d", len(f.sends))}, nil
}

func (f *fakeIMessage) Subscribe(_ context.Context, since int64) (Stream, error) {
	f.mu.Lock()
	f.since = append(f.since, since)
	f.mu.Unlock()
	stream := &fakeStream{messages: make(chan imsg.Message, 16)}
	if f.streams != nil {
		f.streams <- stream
	}
	return stream, nil
}

func (f *fakeIMessage) sent() []fakeSend {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]fakeSend(nil), f.sends...)
}

type fakeStream struct {
	messages chan imsg.Message
	once     sync.Once
}

func (s *fakeStream) Messages() <-chan imsg.Message { return s.messages }
func (s *fakeStream) Err() error                    { return io.EOF }
func (s *fakeStream) Close()                        { s.once.Do(func() { close(s.messages) }) }

type fakeOrka struct {
	*httptest.Server
	mu       sync.Mutex
	events   []protocol.EventEnvelope
	statuses []int
}

func newFakeOrka(t *testing.T) *fakeOrka {
	orka := &fakeOrka{}
	orka.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer inbound-token" || r.URL.Path != "/api/v1/gateways/orka/imessage/events" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		orka.mu.Lock()
		status := http.StatusAccepted
		if len(orka.statuses) > 0 {
			status, orka.statuses = orka.statuses[0], orka.statuses[1:]
		}
		var event protocol.EventEnvelope
		if status == http.StatusAccepted {
			if err := json.NewDecoder(r.Body).Decode(&event); err != nil {
				t.Errorf("decode event: %v", err)
			}
			orka.events = append(orka.events, event)
		}
		orka.mu.Unlock()
		w.WriteHeader(status)
		if status == http.StatusAccepted {
			_ = json.NewEncoder(w).Encode(protocol.IngressResponse{Status: "accepted", EventID: "gwe-1", State: "Queued"})
		}
	}))
	t.Cleanup(orka.Close)
	return orka
}

func (o *fakeOrka) received() []protocol.EventEnvelope {
	o.mu.Lock()
	defer o.mu.Unlock()
	return append([]protocol.EventEnvelope(nil), o.events...)
}

type harness struct {
	server   *Server
	store    *store.Store
	imessage *fakeIMessage
	orka     *fakeOrka
}

func newHarness(t *testing.T, modify func(*Config)) *harness {
	t.Helper()
	database, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "adapter.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	allowlist, err := imessage.ParseAllowlist(testHandle + ",me@example.com")
	if err != nil {
		t.Fatal(err)
	}
	orka := newFakeOrka(t)
	config := Config{
		AccountID: testAccount, Allowlist: allowlist,
		IngressURL:         orka.URL + "/api/v1/gateways/orka/imessage/events",
		IngressBearerToken: "inbound-token", OutboundBearerToken: testOutbound,
		Logger: slog.New(slog.DiscardHandler),
	}
	if modify != nil {
		modify(&config)
	}
	fake := &fakeIMessage{}
	server, err := New(config, database, fake)
	if err != nil {
		t.Fatal(err)
	}
	return &harness{server: server, store: database, imessage: fake, orka: orka}
}

func delivery(id, text string) protocol.DeliveryRequest {
	return protocol.DeliveryRequest{
		ProtocolVersion: protocol.Version, DeliveryID: id, IdempotencyID: id, OriginatingEvent: "gwe-1",
		Kind: protocol.DeliveryKindFinal, AccountID: testAccount, ContextID: testChat, ReplyTarget: testChat, Text: text,
	}
}

func (h *harness) deliver(t *testing.T, request protocol.DeliveryRequest) (int, protocol.DeliveryResponse) {
	t.Helper()
	body, _ := json.Marshal(request)
	return h.post(t, body, testOutbound)
}

func (h *harness) post(t *testing.T, body []byte, token string) (int, protocol.DeliveryResponse) {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, "/v1/deliveries", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	h.server.Handler().ServeHTTP(recorder, request)
	var response protocol.DeliveryResponse
	_ = json.Unmarshal(recorder.Body.Bytes(), &response)
	return recorder.Code, response
}

func TestProtocolRoutesRequireOutboundToken(t *testing.T) {
	h := newHarness(t, nil)
	for _, path := range []string{"/v1/health", "/v1/capabilities"} {
		for token, want := range map[string]int{"": http.StatusUnauthorized, "wrong": http.StatusUnauthorized, testOutbound: http.StatusOK} {
			request := httptest.NewRequest(http.MethodGet, path, nil)
			if token != "" {
				request.Header.Set("Authorization", "Bearer "+token)
			}
			recorder := httptest.NewRecorder()
			h.server.Handler().ServeHTTP(recorder, request)
			if recorder.Code != want {
				t.Errorf("%s with token %q = %d; want %d", path, token, recorder.Code, want)
			}
			if strings.Contains(recorder.Body.String(), testOutbound) {
				t.Errorf("%s leaked the bearer token", path)
			}
		}
	}
	if code, _ := h.post(t, []byte(`{}`), "wrong"); code != http.StatusUnauthorized {
		t.Fatalf("delivery with bad token = %d", code)
	}
	request := httptest.NewRequest(http.MethodGet, "/v1/capabilities", nil)
	request.Header.Set("Authorization", "Bearer "+testOutbound)
	recorder := httptest.NewRecorder()
	h.server.Handler().ServeHTTP(recorder, request)
	var capabilities protocol.CapabilitiesResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &capabilities); err != nil {
		t.Fatal(err)
	}
	if !capabilities.Capabilities.IdempotentDelivery || !capabilities.Capabilities.InterimDelivery || capabilities.Capabilities.Threads {
		t.Fatalf("capabilities = %+v", capabilities.Capabilities)
	}
}

func TestDeliverySendsOnceAndReplays(t *testing.T) {
	h := newHarness(t, nil)
	if err := h.store.RememberReplyChat(context.Background(), testChat); err != nil {
		t.Fatal(err)
	}
	request := delivery("gdl-1", "Hello from Orka")
	for range 3 {
		code, response := h.deliver(t, request)
		if code != http.StatusOK || response.Status != protocol.DeliveryStatusDelivered || response.ProviderMessageID != "GUID-1" {
			t.Fatalf("delivery = %d %+v", code, response)
		}
	}
	retried := request
	retried.DeliveryID = "gdl-1-attempt-2"
	if _, response := h.deliver(t, retried); response.ProviderMessageID != "GUID-1" {
		t.Fatalf("same idempotency ID with a new delivery ID = %+v", response)
	}
	if sends := h.imessage.sent(); len(sends) != 1 || sends[0] != (fakeSend{testChat, "Hello from Orka"}) {
		t.Fatalf("sends = %+v", sends)
	}
	changed := request
	changed.Text = "different"
	if _, response := h.deliver(t, changed); response.Status != protocol.DeliveryStatusNonRetryableError {
		t.Fatalf("conflicting replay = %+v", response)
	}
}

func TestDeliveryOnlyReachesAdmittedAllowlistedChats(t *testing.T) {
	h := newHarness(t, nil)
	ctx := context.Background()
	for _, chat := range []string{"iMessage;-;+14155550000", "iMessage;+;chat42"} {
		if err := h.store.RememberReplyChat(ctx, chat); err != nil {
			t.Fatal(err)
		}
	}
	cases := map[string]func(*protocol.DeliveryRequest){
		"never admitted": func(*protocol.DeliveryRequest) {},
		"not allowlisted": func(r *protocol.DeliveryRequest) {
			r.ContextID, r.ReplyTarget = "iMessage;-;+14155550000", "iMessage;-;+14155550000"
		},
		"group": func(r *protocol.DeliveryRequest) {
			r.ContextID, r.ReplyTarget = "iMessage;+;chat42", "iMessage;+;chat42"
		},
		"account mismatch": func(r *protocol.DeliveryRequest) { r.AccountID = "other" },
		"context mismatch": func(r *protocol.DeliveryRequest) { r.ContextID = "iMessage;-;me@example.com" },
		"thread":           func(r *protocol.DeliveryRequest) { r.ThreadID = "t1" },
		"bad target":       func(r *protocol.DeliveryRequest) { r.ContextID, r.ReplyTarget = "+14155551212", "+14155551212" },
		"conformance off": func(r *protocol.DeliveryRequest) {
			r.AccountID, r.ContextID, r.ReplyTarget = "conformance", "conformance", "conformance"
		},
	}
	for name, modify := range cases {
		request := delivery("gdl-"+strings.ReplaceAll(name, " ", "-"), "hi")
		modify(&request)
		code, response := h.deliver(t, request)
		if code != http.StatusOK || response.Status != protocol.DeliveryStatusNonRetryableError {
			t.Errorf("%s: %d %+v", name, code, response)
		}
	}
	if sends := h.imessage.sent(); len(sends) != 0 {
		t.Fatalf("unauthorized routes sent messages: %+v", sends)
	}
}

func TestConformanceRouteUsesConfiguredAllowlistedChat(t *testing.T) {
	h := newHarness(t, func(c *Config) { c.ConformanceChatGUID = "iMessage;-;me@example.com" })
	request := delivery("conformance-idempotency", "conformance authentication probe")
	request.AccountID, request.ContextID, request.ReplyTarget = conformanceRoute, conformanceRoute, conformanceRoute
	if _, response := h.deliver(t, request); response.Status != protocol.DeliveryStatusDelivered {
		t.Fatalf("conformance delivery = %+v", response)
	}
	if sends := h.imessage.sent(); len(sends) != 1 || sends[0].chat != "iMessage;-;me@example.com" {
		t.Fatalf("sends = %+v", sends)
	}

	allowlist, _ := imessage.ParseAllowlist(testHandle)
	database, _ := store.Open(context.Background(), filepath.Join(t.TempDir(), "x.db"))
	defer database.Close() //nolint:errcheck
	for _, chat := range []string{"iMessage;-;+14155550000", "iMessage;+;chat42", "nonsense"} {
		_, err := New(Config{
			AccountID: testAccount, Allowlist: allowlist, ConformanceChatGUID: chat,
			IngressURL:         "http://127.0.0.1:1/api/v1/gateways/orka/imessage/events",
			IngressBearerToken: "a", OutboundBearerToken: "b",
		}, database, &fakeIMessage{})
		if err == nil {
			t.Errorf("conformance chat %q was accepted", chat)
		}
	}
}

func TestDeliveryOutcomeClassification(t *testing.T) {
	cases := []struct {
		name      string
		result    func() (imsg.SendResult, error)
		status    string
		resendsOn bool
	}{
		{"not dispatched", func() (imsg.SendResult, error) { return imsg.SendResult{}, imsg.ErrNotDispatched }, protocol.DeliveryStatusRetryableError, true},
		{"busy", rpcFailure(imsg.CodeServerBusy, ""), protocol.DeliveryStatusRetryableError, true},
		{"lane blocked", rpcFailure(imsg.CodeMutationLaneBlocked, `{"retry_safe":true}`), protocol.DeliveryStatusRetryableError, true},
		{"failed before dispatch", rpcFailure(imsg.CodeInternal, `{"retry_safe":true,"disposition":"not_started"}`), protocol.DeliveryStatusRetryableError, true},
		{"internal without disposition", rpcFailure(imsg.CodeInternal, `"boom"`), protocol.DeliveryStatusNonRetryableError, false},
		{"outcome unknown", rpcFailure(imsg.CodeOutcomeUnknown, `{"retry_safe":false}`), protocol.DeliveryStatusNonRetryableError, false},
		{"invalid params", rpcFailure(imsg.CodeInvalidParams, `"unknown chat"`), protocol.DeliveryStatusNonRetryableError, false},
		{"no response", func() (imsg.SendResult, error) { return imsg.SendResult{}, imsg.ErrNoResponse }, protocol.DeliveryStatusNonRetryableError, false},
		{"unconfirmed", func() (imsg.SendResult, error) { return imsg.SendResult{}, nil }, protocol.DeliveryStatusNonRetryableError, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t, nil)
			if err := h.store.RememberReplyChat(context.Background(), testChat); err != nil {
				t.Fatal(err)
			}
			h.imessage.results = []func() (imsg.SendResult, error){tc.result}
			request := delivery("gdl-1", "hi")
			if _, response := h.deliver(t, request); response.Status != tc.status {
				t.Fatalf("first attempt = %+v; want %s", response, tc.status)
			}
			_, response := h.deliver(t, request)
			wantSends := 1
			if tc.resendsOn {
				wantSends = 2
				if response.Status != protocol.DeliveryStatusDelivered {
					t.Fatalf("retry = %+v", response)
				}
			} else if response.Status != tc.status {
				t.Fatalf("replay = %+v", response)
			}
			if sends := h.imessage.sent(); len(sends) != wantSends {
				t.Fatalf("sends = %d; want %d", len(sends), wantSends)
			}
		})
	}
}

func rpcFailure(code int, data string) func() (imsg.SendResult, error) {
	return func() (imsg.SendResult, error) {
		return imsg.SendResult{}, &imsg.RPCError{Code: code, Message: "failure", Data: json.RawMessage(data)}
	}
}

func TestDeliveryBounds(t *testing.T) {
	h := newHarness(t, nil)
	interim := delivery("gdl-big", strings.Repeat("x", protocol.MaxInterimTextBytes+1))
	interim.Kind = protocol.DeliveryKindMessage
	if code, response := h.deliver(t, interim); code != http.StatusBadRequest || response.Status != protocol.DeliveryStatusNonRetryableError {
		t.Fatalf("oversized interim = %d %+v", code, response)
	}
	large := bytes.Repeat([]byte(" "), protocol.MaxHTTPBodyBytes+1)
	if code, _ := h.post(t, large, testOutbound); code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized body = %d", code)
	}
}

func inboundMessage(id int64, text string) imsg.Message {
	return imsg.Message{
		ID: id, GUID: fmt.Sprintf("MSG-%d", id), ChatGUID: testChat, ChatIdentifier: testHandle,
		Sender: testHandle, SenderName: "Test Person", Text: text, CreatedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}
}

func TestInboundForwardsAllowlistedText(t *testing.T) {
	h := newHarness(t, nil)
	ctx := context.Background()
	if err := h.server.handleInbound(ctx, inboundMessage(42, " What's up?￼ ")); err != nil {
		t.Fatal(err)
	}
	events := h.orka.received()
	if len(events) != 1 {
		t.Fatalf("events = %+v", events)
	}
	event := events[0]
	if event.ExternalEventID != "MSG-42" || event.AccountID != testAccount || event.ContextID != testChat ||
		event.ReplyTarget != testChat || event.Sender.ID != testHandle || event.Sender.DisplayName != "Test Person" ||
		event.Text != "What's up?" || event.OccurredAt == nil || event.ThreadID != "" || len(event.Metadata) != 0 {
		t.Fatalf("event = %+v", event)
	}
	if cursor, _, _ := h.store.Cursor(ctx); cursor != 42 {
		t.Fatalf("cursor = %d", cursor)
	}
	if known, _ := h.store.ReplyChatKnown(ctx, testChat); !known {
		t.Fatal("reply chat was not recorded")
	}
}

func TestInboundSkipsEverythingElse(t *testing.T) {
	h := newHarness(t, nil)
	ctx := context.Background()
	skipped := map[string]func(*imsg.Message){
		"from me":           func(m *imsg.Message) { m.IsFromMe = true },
		"reaction":          func(m *imsg.Message) { m.IsReaction = true },
		"poll":              func(m *imsg.Message) { m.Poll = json.RawMessage(`{"kind":"created"}`) },
		"other sender":      func(m *imsg.Message) { m.Sender = "+14155550000" },
		"unnormalized":      func(m *imsg.Message) { m.Sender = "4155551212" },
		"other direct chat": func(m *imsg.Message) { m.ChatGUID = "iMessage;-;+14155550000" },
		"group":             func(m *imsg.Message) { m.ChatGUID, m.IsGroup = "iMessage;+;chat42", true },
		"attachment only":   func(m *imsg.Message) { m.Text = "￼" },
		"empty":             func(m *imsg.Message) { m.Text = "  " },
		"missing chat":      func(m *imsg.Message) { m.ChatGUID = "" },
		"missing guid":      func(m *imsg.Message) { m.GUID = "" },
		"oversized":         func(m *imsg.Message) { m.Text = strings.Repeat("x", protocol.MaxTextBytes+1) },
	}
	var rowID int64
	for name, modify := range skipped {
		rowID++
		message := inboundMessage(rowID, "hello")
		modify(&message)
		if err := h.server.handleInbound(ctx, message); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}
	if events := h.orka.received(); len(events) != 0 {
		t.Fatalf("skipped messages reached Orka: %+v", events)
	}
	if cursor, _, _ := h.store.Cursor(ctx); cursor != rowID {
		t.Fatalf("cursor = %d; want %d", cursor, rowID)
	}
	edit := inboundMessage(rowID+10, "edited")
	edit.Type = "edited"
	if err := h.server.handleInbound(ctx, edit); err != nil {
		t.Fatal(err)
	}
	if cursor, _, _ := h.store.Cursor(ctx); cursor != rowID {
		t.Fatalf("an edit advanced the cursor to %d", cursor)
	}
	if known, _ := h.store.ReplyChatKnown(ctx, "iMessage;-;+14155550000"); known {
		t.Fatal("a skipped chat became a reply target")
	}
}

func TestInboundIgnoresStaleRows(t *testing.T) {
	h := newHarness(t, nil)
	stale := inboundMessage(1, "from yesterday")
	stale.CreatedAt = time.Now().Add(-maxMessageAge - time.Minute).UTC().Format(time.RFC3339Nano)
	if err := h.server.handleInbound(context.Background(), stale); err != nil {
		t.Fatal(err)
	}
	if events := h.orka.received(); len(events) != 0 {
		t.Fatalf("stale row reached Orka: %+v", events)
	}
}

func TestInboundSuppressesEchoOfAdapterSend(t *testing.T) {
	selfChat := "iMessage;-;me@example.com"
	h := newHarness(t, nil)
	ctx := context.Background()
	first := inboundMessage(1, "ping")
	first.ChatGUID, first.Sender = selfChat, "me@example.com"
	if err := h.server.handleInbound(ctx, first); err != nil {
		t.Fatal(err)
	}
	reply := delivery("gdl-1", "pong")
	reply.ContextID, reply.ReplyTarget = selfChat, selfChat
	if _, response := h.deliver(t, reply); response.Status != protocol.DeliveryStatusDelivered {
		t.Fatalf("reply = %+v", response)
	}
	// The echo row carries the send time even when it is processed later,
	// for example after a restart.
	echo := inboundMessage(2, "pong")
	echo.ChatGUID, echo.Sender = selfChat, "Me@Example.com"
	echo.CreatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	if err := h.server.handleInbound(ctx, echo); err != nil {
		t.Fatal(err)
	}
	// The same text written well before the reply is the user's own message.
	earlier := inboundMessage(3, "pong")
	earlier.ChatGUID, earlier.Sender = selfChat, "me@example.com"
	earlier.CreatedAt = time.Now().Add(-time.Hour).UTC().Format(time.RFC3339Nano)
	if err := h.server.handleInbound(ctx, earlier); err != nil {
		t.Fatal(err)
	}
	events := h.orka.received()
	if len(events) != 2 || events[0].Text != "ping" || events[1].ExternalEventID != "MSG-3" {
		t.Fatalf("events = %+v", events)
	}
}

func TestInboundRetriesTransientIngressAndSkipsRejectedEvents(t *testing.T) {
	h := newHarness(t, nil)
	h.orka.statuses = []int{http.StatusServiceUnavailable, http.StatusAccepted, http.StatusBadRequest}
	ctx := context.Background()
	if err := h.server.handleInbound(ctx, inboundMessage(1, "retry me")); err != nil {
		t.Fatal(err)
	}
	if err := h.server.handleInbound(ctx, inboundMessage(2, "rejected")); err != nil {
		t.Fatal(err)
	}
	if events := h.orka.received(); len(events) != 1 || events[0].Text != "retry me" {
		t.Fatalf("events = %+v", events)
	}
	if cursor, _, _ := h.store.Cursor(ctx); cursor != 2 {
		t.Fatalf("cursor = %d", cursor)
	}
}

func runWatch(t *testing.T, h *harness, feed func(stream *fakeStream)) []int64 {
	t.Helper()
	h.imessage.streams = make(chan *fakeStream, 2)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		h.server.RunInbound(ctx)
	}()
	stream := <-h.imessage.streams
	feed(stream)
	stream.Close()
	<-h.imessage.streams
	cancel()
	<-done
	h.imessage.mu.Lock()
	defer h.imessage.mu.Unlock()
	return append([]int64(nil), h.imessage.since...)
}

func TestWatchResumesFromDurableCursor(t *testing.T) {
	h := newHarness(t, nil)
	if err := h.store.AdvanceCursor(context.Background(), 41); err != nil {
		t.Fatal(err)
	}
	since := runWatch(t, h, func(stream *fakeStream) { stream.messages <- inboundMessage(42, "hello") })
	if len(since) != 2 || since[0] != 41 || since[1] != 42 || h.imessage.latests != 0 {
		t.Fatalf("subscriptions resumed from %v after %d tail lookups", since, h.imessage.latests)
	}
}

func TestWatchFirstStartPersistsTheNewestRow(t *testing.T) {
	h := newHarness(t, nil)
	h.imessage.latest = 900
	// No message arrives before the restart: the second subscription must
	// still resume from the persisted tail rather than a new one.
	since := runWatch(t, h, func(*fakeStream) {})
	if len(since) != 2 || since[0] != 900 || since[1] != 900 || h.imessage.latests != 1 {
		t.Fatalf("subscriptions = %v after %d tail lookups", since, h.imessage.latests)
	}
	if events := h.orka.received(); len(events) != 0 {
		t.Fatalf("history reached Orka: %+v", events)
	}
}

func TestWatchEmptyDatabaseReplaysFromTheFirstRow(t *testing.T) {
	h := newHarness(t, nil)
	since := runWatch(t, h, func(*fakeStream) {})
	if len(since) != 2 || since[0] != -1 || since[1] != -1 {
		t.Fatalf("subscriptions = %v", since)
	}
}

func TestNewRejectsUnsafeConfiguration(t *testing.T) {
	database, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "adapter.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close() //nolint:errcheck
	allowlist, _ := imessage.ParseAllowlist(testHandle)
	valid := Config{
		AccountID: testAccount, Allowlist: allowlist,
		IngressURL:         "https://orka.example.com/api/v1/gateways/orka/imessage/events",
		IngressBearerToken: "in", OutboundBearerToken: "out",
	}
	if _, err := New(valid, database, &fakeIMessage{}); err != nil {
		t.Fatalf("valid config: %v", err)
	}
	for name, modify := range map[string]func(*Config){
		"no allowlist":      func(c *Config) { c.Allowlist = imessage.Allowlist{} },
		"no account":        func(c *Config) { c.AccountID = "" },
		"same tokens":       func(c *Config) { c.OutboundBearerToken = c.IngressBearerToken },
		"plaintext remote":  func(c *Config) { c.IngressURL = "http://orka.example.com/api/v1/gateways/orka/imessage/events" },
		"wrong path":        func(c *Config) { c.IngressURL = "https://orka.example.com/api/v1/events" },
		"credentials":       func(c *Config) { c.IngressURL = "https://u:p@orka.example.com/api/v1/gateways/orka/imessage/events" },
		"missing transport": func(c *Config) { c.IngressBearerToken = "" },
	} {
		config := valid
		modify(&config)
		if _, err := New(config, database, &fakeIMessage{}); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	loopback := valid
	loopback.IngressURL = "http://127.0.0.1:8081/api/v1/gateways/orka/imessage/events"
	if _, err := New(loopback, database, &fakeIMessage{}); err != nil {
		t.Fatalf("loopback port-forward ingress: %v", err)
	}
}

func TestInboundForwardsOneOfSeveralSelfChatCopies(t *testing.T) {
	h := newHarness(t, nil)
	ctx := context.Background()
	sent := time.Now().Add(-time.Minute)
	copyAt := func(id int64, offset time.Duration) imsg.Message {
		message := inboundMessage(id, "same text")
		message.CreatedAt = sent.Add(offset).UTC().Format(time.RFC3339Nano)
		return message
	}
	// Messages stores one self-chat message as two received rows with their
	// own GUIDs; the second can be inserted much later with the original time.
	for _, message := range []imsg.Message{copyAt(10, 0), copyAt(285, 1750*time.Millisecond)} {
		if err := h.server.handleInbound(ctx, message); err != nil {
			t.Fatal(err)
		}
	}
	// A replay of the forwarded row itself is not a copy; Orka deduplicates it.
	if err := h.server.handleInbound(ctx, copyAt(10, 0)); err != nil {
		t.Fatal(err)
	}
	// The same text sent again later is a new message.
	if err := h.server.handleInbound(ctx, copyAt(300, time.Minute/2)); err != nil {
		t.Fatal(err)
	}
	var guids []string
	for _, event := range h.orka.received() {
		guids = append(guids, event.ExternalEventID)
	}
	if strings.Join(guids, ",") != "MSG-10,MSG-10,MSG-300" {
		t.Fatalf("forwarded %v", guids)
	}
}
