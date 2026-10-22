package imsg

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

const (
	minRestartBackoff = time.Second
	maxRestartBackoff = 30 * time.Second
	healthyLifetime   = 10 * time.Second
	closeTimeout      = 10 * time.Second
)

// Supervisor owns at most one imsg rpc child and restarts it on demand with
// bounded backoff. It is safe for concurrent use.
type Supervisor struct {
	options Options
	logger  *slog.Logger
	start   func(context.Context, Options) (*Client, error)

	mu        sync.Mutex
	client    *Client
	startedAt time.Time
	retryAt   time.Time
	backoff   time.Duration
	closed    bool
}

// NewSupervisor returns a supervisor that starts children lazily.
func NewSupervisor(options Options) *Supervisor {
	logger := options.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &Supervisor{options: options, logger: logger, start: Start}
}

// Status starts the child if needed and returns its initialize snapshot.
func (s *Supervisor) Status(ctx context.Context) (Status, error) {
	client, err := s.current(ctx)
	if err != nil {
		return Status{}, err
	}
	return client.Status(), nil
}

// Send sends text to an existing chat. See Client.Send for error semantics.
func (s *Supervisor) Send(ctx context.Context, chatGUID, text string) (SendResult, error) {
	client, err := s.current(ctx)
	if err != nil {
		return SendResult{}, err
	}
	result, err := client.Send(ctx, chatGUID, text)
	var rpcErr *RPCError
	if errors.As(err, &rpcErr) && rpcErr.Code == CodeMutationLaneBlocked {
		// imsg poisons its mutation lane after an uncertain send until the
		// child restarts. The uncertain send is already recorded as unknown.
		s.restart(client)
	}
	return result, err
}

// Subscribe starts an all-chat watch on the current child.
func (s *Supervisor) Subscribe(ctx context.Context, sinceRowID int64) (*Subscription, error) {
	client, err := s.current(ctx)
	if err != nil {
		return nil, err
	}
	return client.Subscribe(ctx, sinceRowID)
}

// Close stops the child, letting it drain accepted requests first.
func (s *Supervisor) Close() {
	s.mu.Lock()
	client := s.client
	s.client = nil
	s.closed = true
	s.mu.Unlock()
	if client != nil {
		_ = client.Close(closeTimeout)
	}
}

func (s *Supervisor) current(ctx context.Context) (*Client, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, fmt.Errorf("%w: %w", ErrNotDispatched, ErrClosed)
	}
	if s.client != nil {
		select {
		case <-s.client.Done():
			s.logger.Warn("imsg rpc child exited", "error", safeError(s.client.Err()))
			s.client = nil
			if time.Since(s.startedAt) < healthyLifetime {
				s.delayRestart()
			} else {
				s.backoff = 0
			}
		default:
			return s.client, nil
		}
	}
	if time.Now().Before(s.retryAt) {
		return nil, fmt.Errorf("%w: imsg rpc restart is backing off", ErrNotDispatched)
	}
	client, err := s.start(ctx, s.options)
	if err != nil {
		s.delayRestart()
		return nil, fmt.Errorf("%w: %w", ErrNotDispatched, err)
	}
	status := client.Status()
	s.logger.Info("imsg rpc started", "imsg_version", status.Version, "database_ready", status.Database.Ready)
	if !status.Database.Ready {
		s.logger.Warn("Messages database is unavailable; grant Full Disk Access to the process running the adapter",
			"detail", safeError(errors.New(status.Database.Error)))
	}
	s.client = client
	s.startedAt = time.Now()
	return client, nil
}

func (s *Supervisor) restart(client *Client) {
	s.mu.Lock()
	if s.client != client {
		s.mu.Unlock()
		return
	}
	s.client = nil
	s.mu.Unlock()
	s.logger.Warn("restarting imsg rpc child after a blocked mutation lane")
	go func() { _ = client.Close(closeTimeout) }()
}

func (s *Supervisor) delayRestart() {
	if s.backoff == 0 {
		s.backoff = minRestartBackoff
	} else {
		s.backoff = min(2*s.backoff, maxRestartBackoff)
	}
	s.retryAt = time.Now().Add(s.backoff)
}

func safeError(err error) string {
	if err == nil {
		return ""
	}
	message := err.Error()
	if len(message) > 512 {
		message = message[:512]
	}
	return message
}
