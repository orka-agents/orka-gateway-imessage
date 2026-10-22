// Package adapter implements the orka.gateway.v1 adapter for iMessage.
package adapter

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"

	"github.com/orka-agents/orka-gateway-imessage/internal/imessage"
	"github.com/orka-agents/orka-gateway-imessage/internal/imsg"
	"github.com/orka-agents/orka-gateway-imessage/internal/protocol"
	"github.com/orka-agents/orka-gateway-imessage/internal/store"
)

// conformanceRoute is the account, context, and reply target Orka's
// conformance tool uses for its delivery probes.
const conformanceRoute = "conformance"

// Stream is one Messages watch subscription.
type Stream interface {
	Messages() <-chan imsg.Message
	Err() error
	Close()
}

// IMessage is the Messages bridge the adapter drives.
type IMessage interface {
	Send(ctx context.Context, chatGUID, text string) (imsg.SendResult, error)
	// Subscribe watches all chats after sinceRowID; -1 replays from the first row.
	Subscribe(ctx context.Context, sinceRowID int64) (Stream, error)
	// LatestRowID returns the newest message row, or 0 when there is none.
	LatestRowID(ctx context.Context) (int64, error)
}

// FromSupervisor adapts an imsg supervisor to IMessage.
func FromSupervisor(supervisor *imsg.Supervisor) IMessage { return supervisorBridge{supervisor} }

type supervisorBridge struct{ *imsg.Supervisor }

func (b supervisorBridge) Subscribe(ctx context.Context, sinceRowID int64) (Stream, error) {
	subscription, err := b.Supervisor.Subscribe(ctx, sinceRowID)
	if err != nil {
		return nil, err
	}
	return subscription, nil
}

// Config configures the adapter.
type Config struct {
	// AccountID is the stable Orka accountId for this Messages account.
	AccountID string
	// Allowlist bounds every inbound sender and outbound chat. Only direct
	// chats are supported: a group reply would reach every member.
	Allowlist imessage.Allowlist
	// ConformanceChatGUID optionally receives Orka conformance probe sends.
	ConformanceChatGUID string
	IngressURL          string
	IngressBearerToken  string
	OutboundBearerToken string
	AdapterName         string
	AdapterVersion      string
	SendTimeout         time.Duration
	HTTPClient          *http.Client
	Logger              *slog.Logger
}

// Server serves the adapter protocol and forwards inbound Messages to Orka.
type Server struct {
	config   Config
	store    *store.Store
	imessage IMessage
	client   *http.Client
	logger   *slog.Logger
	handler  http.Handler
	// sendGate serializes sends so a sending record always means a send is
	// in flight in this process; imsg also runs mutations one at a time.
	sendGate chan struct{}
}

// New validates config and returns a Server.
func New(config Config, database *store.Store, bridge IMessage) (*Server, error) {
	if database == nil || bridge == nil {
		return nil, errors.New("store and iMessage bridge are required")
	}
	if !protocol.ValidIdentity(config.AccountID) {
		return nil, errors.New("account ID is invalid")
	}
	if config.Allowlist.Len() == 0 {
		return nil, errors.New("sender allowlist is required")
	}
	if strings.TrimSpace(config.IngressBearerToken) == "" || strings.TrimSpace(config.OutboundBearerToken) == "" {
		return nil, errors.New("inbound and outbound Orka bearer tokens are required")
	}
	if config.IngressBearerToken == config.OutboundBearerToken {
		return nil, errors.New("inbound and outbound Orka bearer tokens must differ")
	}
	ingressURL, err := validateIngressURL(config.IngressURL)
	if err != nil {
		return nil, err
	}
	config.IngressURL = ingressURL
	if config.ConformanceChatGUID != "" {
		chat, err := imessage.ParseChatGUID(config.ConformanceChatGUID)
		if err != nil || chat.Group || !config.Allowlist.Contains(chat.Identifier) {
			return nil, errors.New("conformance chat must be a direct chat with an allowlisted handle")
		}
	}
	if config.AdapterName == "" {
		config.AdapterName = "orka-gateway-imessage"
	}
	if config.AdapterVersion == "" {
		config.AdapterVersion = "dev"
	}
	if config.SendTimeout <= 0 {
		config.SendTimeout = time.Minute
	}
	client := &http.Client{Timeout: 15 * time.Second}
	if config.HTTPClient != nil {
		copied := *config.HTTPClient
		client = &copied
	}
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	if client.Transport == nil {
		transport := http.DefaultTransport.(*http.Transport).Clone()
		transport.Proxy = nil
		client.Transport = transport
	}
	logger := config.Logger
	if logger == nil {
		logger = slog.Default()
	}
	server := &Server{
		config: config, store: database, imessage: bridge, client: client, logger: logger,
		sendGate: make(chan struct{}, 1),
	}
	server.handler = server.routes()
	return server, nil
}

// Handler returns the HTTP handler.
func (s *Server) Handler() http.Handler { return s.handler }

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, protocol.HealthResponse{Status: "ok"})
	})
	mux.HandleFunc("GET /readyz", s.handleReady)
	mux.HandleFunc("GET /v1/health", s.auth(func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, protocol.HealthResponse{Status: "ok"})
	}))
	mux.HandleFunc("GET /v1/capabilities", s.auth(s.handleCapabilities))
	mux.HandleFunc("POST /v1/deliveries", s.auth(s.handleDelivery))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'none'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		mux.ServeHTTP(w, r)
	})
}

func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !protocol.ConstantTimeBearerEqual(protocol.BearerToken(r.Header.Get("Authorization")), s.config.OutboundBearerToken) {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		next(w, r)
	}
}

func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), time.Second)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, protocol.HealthResponse{Status: "unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, protocol.HealthResponse{Status: "ok"})
}

func (s *Server) handleCapabilities(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, protocol.CapabilitiesResponse{
		ProtocolVersion: protocol.Version,
		AdapterName:     s.config.AdapterName,
		AdapterVersion:  s.config.AdapterVersion,
		Capabilities: protocol.Capabilities{
			InboundText: true, OutboundText: true, SenderIdentity: true,
			IdempotentDelivery: true, InterimDelivery: true,
		},
	})
}

func (s *Server) handleDelivery(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, protocol.MaxHTTPBodyBytes+1))
	if err != nil || len(body) > protocol.MaxHTTPBodyBytes {
		writeJSON(w, http.StatusRequestEntityTooLarge, rejected("invalid request body"))
		return
	}
	request, err := protocol.DecodeDeliveryRequest(body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, rejected("invalid delivery"))
		return
	}
	digest, err := deliveryDigest(request)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, rejected("invalid delivery"))
		return
	}
	if record, found, err := s.store.GetDelivery(r.Context(), request.IdempotencyID); err != nil {
		writeJSON(w, http.StatusOK, retryable("delivery store unavailable"))
		return
	} else if found && record.RequestDigest != digest {
		writeJSON(w, http.StatusOK, rejected("delivery identity conflict"))
		return
	} else if found && record.State.Terminal() {
		writeJSON(w, http.StatusOK, replay(record))
		return
	}

	select {
	case s.sendGate <- struct{}{}:
		defer func() { <-s.sendGate }()
	case <-r.Context().Done():
		writeJSON(w, http.StatusOK, retryable("delivery is in progress"))
		return
	}
	chatGUID, err := s.deliveryChat(r.Context(), request)
	var route routeError
	if errors.As(err, &route) {
		s.logger.Warn("rejected iMessage delivery route", "delivery_id", request.DeliveryID, "reason", route.reason)
		writeJSON(w, http.StatusOK, rejected(route.reason))
		return
	}
	if err != nil {
		writeJSON(w, http.StatusOK, retryable("delivery store unavailable"))
		return
	}
	record, shouldSend, err := s.store.ClaimDelivery(r.Context(), request.IdempotencyID, digest, chatGUID, store.TextDigest(request.Text))
	if errors.Is(err, store.ErrDigestConflict) {
		writeJSON(w, http.StatusOK, rejected("delivery identity conflict"))
		return
	}
	if err != nil {
		writeJSON(w, http.StatusOK, retryable("delivery store unavailable"))
		return
	}
	if !shouldSend {
		writeJSON(w, http.StatusOK, replay(record))
		return
	}

	// Detach from the caller so an Orka-side timeout cannot abandon a send
	// that imsg has already started; a retry replays the stored outcome.
	sendCtx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), s.config.SendTimeout)
	result, sendErr := s.imessage.Send(sendCtx, chatGUID, request.Text)
	cancel()
	state, providerID, message := classifySend(result, sendErr)
	persistCtx, cancelPersist := context.WithTimeout(context.WithoutCancel(r.Context()), 10*time.Second)
	defer cancelPersist()
	finished, err := s.store.FinishDelivery(persistCtx, request.IdempotencyID, digest, state, providerID, message)
	if err != nil {
		// Report the provider outcome truthfully. A restart will mark the
		// unpersisted sending record unknown, which never resends.
		s.logger.Error("failed to persist iMessage delivery result", "delivery_id", request.DeliveryID, "error", safeError(err))
		finished = store.DeliveryRecord{State: state, ProviderMessageID: providerID, SafeMessage: message}
	}
	logArgs := []any{"delivery_id", request.DeliveryID, "kind", request.Kind, "state", string(state)}
	if sendErr != nil {
		logArgs = append(logArgs, "error", safeError(sendErr))
	}
	s.logger.Info("processed iMessage delivery", logArgs...)
	writeJSON(w, http.StatusOK, replay(finished))
}

type routeError struct{ reason string }

func (e routeError) Error() string { return e.reason }

// deliveryChat resolves and authorizes the destination chat. Orka can only
// reply to a direct chat that produced an admitted inbound message and whose
// handle is still allowlisted.
func (s *Server) deliveryChat(ctx context.Context, request *protocol.DeliveryRequest) (string, error) {
	if request.AccountID == conformanceRoute && request.ContextID == conformanceRoute &&
		request.ReplyTarget == conformanceRoute && request.ThreadID == "" {
		if s.config.ConformanceChatGUID == "" {
			return "", routeError{"conformance chat is not configured"}
		}
		return s.config.ConformanceChatGUID, nil
	}
	if request.AccountID != s.config.AccountID || request.ContextID != request.ReplyTarget || request.ThreadID != "" {
		return "", routeError{"delivery routing mismatch"}
	}
	chat, err := imessage.ParseChatGUID(request.ReplyTarget)
	if err != nil {
		return "", routeError{"delivery routing mismatch"}
	}
	if !s.chatAllowed(chat) {
		return "", routeError{"destination is not allowlisted"}
	}
	known, err := s.store.ReplyChatKnown(ctx, chat.GUID)
	if err != nil {
		return "", err
	}
	if !known {
		return "", routeError{"destination has no admitted inbound message"}
	}
	return chat.GUID, nil
}

func (s *Server) chatAllowed(chat imessage.Chat) bool {
	return !chat.Group && s.config.Allowlist.Contains(chat.Identifier)
}

// classifySend maps an imsg send outcome to a durable delivery state. Only
// outcomes imsg proves were never dispatched are retryable.
func classifySend(result imsg.SendResult, err error) (store.DeliveryState, string, string) {
	if err == nil {
		if !result.OK {
			return store.DeliveryUnknown, "", "iMessage send was not confirmed"
		}
		providerID := result.GUID
		if !protocol.ValidIdentity(providerID) {
			providerID = ""
		}
		return store.DeliveryDelivered, providerID, ""
	}
	if errors.Is(err, imsg.ErrNotDispatched) {
		return store.DeliveryRetryable, "", "iMessage bridge is unavailable"
	}
	var rpcErr *imsg.RPCError
	if !errors.As(err, &rpcErr) {
		return store.DeliveryUnknown, "", "iMessage delivery outcome is unknown"
	}
	switch rpcErr.Code {
	case imsg.CodeServerBusy, imsg.CodeDatabaseUnavailable, imsg.CodeBridgeUnavailable, imsg.CodeMutationLaneBlocked:
		return store.DeliveryRetryable, "", "iMessage bridge is temporarily unavailable"
	case imsg.CodeInvalidParams, imsg.CodeInvalidRequest, imsg.CodeMethodNotFound, imsg.CodeParseError:
		return store.DeliveryPermanent, "", "iMessage rejected the send request"
	case imsg.CodeInternal:
		if safe, known := rpcErr.RetrySafe(); known && safe {
			return store.DeliveryRetryable, "", "iMessage send failed before dispatch"
		}
	}
	return store.DeliveryUnknown, "", "iMessage delivery outcome is unknown"
}

func deliveryDigest(request *protocol.DeliveryRequest) (string, error) {
	canonical := *request
	canonical.DeliveryID = canonical.IdempotencyID
	payload, err := json.Marshal(&canonical)
	if err != nil {
		return "", err
	}
	return store.Digest(payload), nil
}

func replay(record store.DeliveryRecord) protocol.DeliveryResponse {
	switch record.State {
	case store.DeliveryDelivered:
		return protocol.DeliveryResponse{Status: protocol.DeliveryStatusDelivered, ProviderMessageID: record.ProviderMessageID}
	case store.DeliveryPermanent, store.DeliveryUnknown:
		return rejected(defaultString(record.SafeMessage, "delivery could not be completed"))
	default:
		return retryable(defaultString(record.SafeMessage, "delivery is in progress"))
	}
}

func rejected(message string) protocol.DeliveryResponse {
	return protocol.DeliveryResponse{Status: protocol.DeliveryStatusNonRetryableError, Message: message}
}

func retryable(message string) protocol.DeliveryResponse {
	return protocol.DeliveryResponse{Status: protocol.DeliveryStatusRetryableError, Message: message}
}

func defaultString(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func validateIngressURL(raw string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return "", errors.New("orka ingress URL must be absolute")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", errors.New("orka ingress URL must use http or https")
	}
	if parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", errors.New("orka ingress URL must not contain credentials, query, or fragment")
	}
	parts := strings.Split(strings.Trim(parsed.EscapedPath(), "/"), "/")
	if len(parts) != 6 || parts[0] != "api" || parts[1] != "v1" || parts[2] != "gateways" || parts[3] == "" || parts[4] == "" || parts[5] != "events" {
		return "", errors.New("orka ingress URL path must be /api/v1/gateways/<namespace>/<name>/events")
	}
	if parsed.Scheme == "http" && !isLoopbackHost(parsed.Hostname()) {
		return "", errors.New("plaintext Orka ingress is allowed only for loopback, such as a kubectl port-forward")
	}
	return parsed.String(), nil
}

func isLoopbackHost(host string) bool {
	host = strings.ToLower(strings.Trim(host, "[]"))
	if host == "localhost" {
		return true
	}
	address, err := netip.ParseAddr(host)
	return err == nil && address.IsLoopback()
}

func safeError(err error) string {
	if err == nil {
		return ""
	}
	return protocol.SanitizeMessage(err.Error(), 512)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
