package imsg

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	maxLineBytes    = 8 << 20
	eventBuffer     = 128
	initTimeout     = 15 * time.Second
	unsubscribeWait = 5 * time.Second
)

// Options configure an imsg rpc child process.
type Options struct {
	// Path is the imsg executable.
	Path string
	// DatabasePath optionally overrides the Messages database (imsg --db).
	DatabasePath string
	// Env is the child environment. Use ChildEnvironment to drop adapter secrets.
	Env    []string
	Logger *slog.Logger
}

// ChildEnvironment returns environ without the adapter's ORKA_* settings so
// gateway credentials never reach the imsg process tree.
func ChildEnvironment(environ []string) []string {
	env := make([]string, 0, len(environ))
	for _, entry := range environ {
		if !strings.HasPrefix(entry, "ORKA_") {
			env = append(env, entry)
		}
	}
	return env
}

// Client is one running imsg rpc child. It is safe for concurrent use.
type Client struct {
	logger  *slog.Logger
	stdin   io.WriteCloser
	kill    func()
	writeMu sync.Mutex

	mu      sync.Mutex
	nextID  int64
	pending map[int64]*pendingCall
	subs    map[int64]*Subscription
	closed  bool
	err     error
	done    chan struct{}

	status Status
}

type pendingCall struct {
	done chan rpcResponse
	// hook runs on the reader goroutine before the response is handed to the
	// caller, so state it registers is visible before later notifications.
	hook func(json.RawMessage) any
}

type rpcResponse struct {
	result    json.RawMessage
	value     any
	rpcErr    *RPCError
	transport error
}

type wireRequest struct {
	JSONRPC string `json:"jsonrpc"`
	ID      int64  `json:"id"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
}

type wireMessage struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
	Error  *RPCError       `json:"error"`
}

// Start launches `imsg rpc` and waits for its initialize response.
func Start(ctx context.Context, options Options) (*Client, error) {
	logger := options.Logger
	if logger == nil {
		logger = slog.Default()
	}
	args := []string{"rpc"}
	if options.DatabasePath != "" {
		args = append(args, "--db", options.DatabasePath)
	}
	cmd := exec.Command(options.Path, args...) // #nosec G204 -- operator-configured imsg executable
	cmd.Env = options.Env
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start imsg rpc: %w", err)
	}
	var stderrDone sync.WaitGroup
	stderrDone.Add(1)
	go func() {
		defer stderrDone.Done()
		logDiagnostics(stderr, logger)
	}()
	client := newClient(stdin, stdout, func() { _ = cmd.Process.Kill() }, func() error {
		stderrDone.Wait()
		return cmd.Wait()
	}, logger)

	initCtx, cancel := context.WithTimeout(ctx, initTimeout)
	defer cancel()
	var status Status
	if err := client.Call(initCtx, "initialize", map[string]any{"protocol_version": 1}, &status); err != nil {
		_ = client.Close(5 * time.Second)
		return nil, fmt.Errorf("initialize imsg rpc: %w", err)
	}
	client.status = status
	return client, nil
}

func newClient(stdin io.WriteCloser, stdout io.Reader, kill func(), wait func() error, logger *slog.Logger) *Client {
	client := &Client{
		logger: logger, stdin: stdin, kill: kill,
		pending: map[int64]*pendingCall{}, subs: map[int64]*Subscription{},
		done: make(chan struct{}),
	}
	go client.readLoop(stdout, wait)
	return client
}

// Status returns the snapshot reported by initialize.
func (c *Client) Status() Status { return c.status }

// Done is closed when the child exits.
func (c *Client) Done() <-chan struct{} { return c.done }

// Err reports why the child exited.
func (c *Client) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.err
}

// Close closes stdin so imsg drains accepted requests and exits, killing it
// after timeout.
func (c *Client) Close(timeout time.Duration) error {
	_ = c.stdin.Close()
	select {
	case <-c.done:
	case <-time.After(timeout):
		c.kill()
		<-c.done
	}
	return nil
}

// Call sends one request and decodes its result into result (when non-nil).
func (c *Client) Call(ctx context.Context, method string, params any, result any) error {
	raw, _, err := c.call(ctx, method, params, nil)
	if err != nil || result == nil {
		return err
	}
	if err := json.Unmarshal(raw, result); err != nil {
		return fmt.Errorf("%w: invalid %s result", ErrNoResponse, method)
	}
	return nil
}

// Send sends text to an existing chat. Errors wrap ErrNotDispatched when the
// request never reached imsg, ErrNoResponse when the outcome is unknown, or
// are an *RPCError.
func (c *Client) Send(ctx context.Context, chatGUID, text string) (SendResult, error) {
	var result SendResult
	err := c.Call(ctx, "send", map[string]any{"chat_guid": chatGUID, "text": text}, &result)
	return result, err
}

// Subscribe starts an all-chat watch. sinceRowID > 0 resumes after that
// message row, -1 replays from the first row, and 0 starts at the current tail.
func (c *Client) Subscribe(ctx context.Context, sinceRowID int64) (*Subscription, error) {
	params := map[string]any{}
	if sinceRowID != 0 {
		params["since_rowid"] = max(sinceRowID, -1)
	}
	_, value, err := c.call(ctx, "watch.subscribe", params, func(raw json.RawMessage) any {
		var response struct {
			Subscription int64 `json:"subscription"`
		}
		if json.Unmarshal(raw, &response) != nil || response.Subscription <= 0 {
			return nil
		}
		sub := &Subscription{id: response.Subscription, client: c, messages: make(chan Message, eventBuffer)}
		c.mu.Lock()
		if c.closed {
			c.finishLocked(sub, ErrClosed)
		} else {
			c.subs[sub.id] = sub
		}
		c.mu.Unlock()
		return sub
	})
	if err != nil {
		return nil, err
	}
	sub, ok := value.(*Subscription)
	if !ok {
		return nil, errors.New("imsg returned an invalid subscription")
	}
	return sub, nil
}

// LatestRowID returns the newest message row visible to imsg, or 0 when the
// database has none. It searches with one-row messages.after pages rather than
// reading history.
func (c *Client) LatestRowID(ctx context.Context) (int64, error) {
	// rowsAfter reports whether any message row is newer than rowID.
	rowsAfter := func(rowID int64) (bool, error) {
		var page struct {
			Messages  []json.RawMessage `json:"messages"`
			NextRowID int64             `json:"next_rowid"`
			HasMore   bool              `json:"has_more"`
		}
		err := c.Call(ctx, "messages.after", map[string]any{"since_rowid": rowID, "limit": 1, "include_reactions": true}, &page)
		return len(page.Messages) > 0 || page.HasMore || page.NextRowID > rowID, err
	}
	// Find the smallest row with nothing newer: grow an upper bound, then bisect.
	low, high := int64(0), int64(1)
	if found, err := rowsAfter(low); err != nil || !found {
		return 0, err
	}
	for {
		found, err := rowsAfter(high)
		if err != nil {
			return 0, err
		}
		if !found {
			break
		}
		if high > 1<<52 {
			return 0, errors.New("imsg message rows exceed the supported range")
		}
		low, high = high, high*2
	}
	for high-low > 1 {
		middle := low + (high-low)/2
		found, err := rowsAfter(middle)
		if err != nil {
			return 0, err
		}
		if found {
			low = middle
		} else {
			high = middle
		}
	}
	return high, nil
}

func (c *Client) call(ctx context.Context, method string, params any, hook func(json.RawMessage) any) (json.RawMessage, any, error) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil, nil, fmt.Errorf("%w: %w", ErrNotDispatched, ErrClosed)
	}
	c.nextID++
	id := c.nextID
	call := &pendingCall{done: make(chan rpcResponse, 1), hook: hook}
	c.pending[id] = call
	c.mu.Unlock()

	line, err := json.Marshal(wireRequest{JSONRPC: "2.0", ID: id, Method: method, Params: params})
	if err != nil {
		c.forget(id)
		return nil, nil, fmt.Errorf("%w: encode request: %w", ErrNotDispatched, err)
	}
	c.writeMu.Lock()
	_, err = c.stdin.Write(append(line, '\n'))
	c.writeMu.Unlock()
	if err != nil {
		c.forget(id)
		return nil, nil, fmt.Errorf("%w: write request: %w", ErrNotDispatched, err)
	}

	var response rpcResponse
	select {
	case response = <-call.done:
	case <-ctx.Done():
		if c.forget(id) {
			return nil, nil, fmt.Errorf("%w: %w", ErrNoResponse, ctx.Err())
		}
		// The reader already claimed this call; its response is in flight.
		response = <-call.done
	}
	switch {
	case response.transport != nil:
		return nil, nil, response.transport
	case response.rpcErr != nil:
		return nil, nil, response.rpcErr
	default:
		return response.result, response.value, nil
	}
}

func (c *Client) forget(id int64) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	_, ok := c.pending[id]
	delete(c.pending, id)
	return ok
}

func (c *Client) readLoop(stdout io.Reader, wait func() error) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64<<10), maxLineBytes)
	for scanner.Scan() {
		c.handleLine(scanner.Bytes())
	}
	err := scanner.Err()
	if err != nil {
		c.kill()
	}
	waitErr := wait()
	if err == nil {
		err = waitErr
	}
	if err == nil {
		err = io.EOF
	}
	c.shutdown(err)
}

func (c *Client) handleLine(line []byte) {
	var message wireMessage
	if err := json.Unmarshal(line, &message); err != nil {
		c.logger.Warn("ignoring invalid imsg rpc output")
		return
	}
	if message.Method != "" && len(message.ID) == 0 {
		c.handleNotification(message.Method, message.Params)
		return
	}
	id, err := strconv.ParseInt(string(message.ID), 10, 64)
	if err != nil {
		if message.Error != nil {
			c.logger.Warn("imsg rpc reported an uncorrelated error", "code", message.Error.Code)
		}
		return
	}
	c.mu.Lock()
	call := c.pending[id]
	delete(c.pending, id)
	c.mu.Unlock()
	if call == nil {
		return
	}
	response := rpcResponse{result: message.Result, rpcErr: message.Error}
	if message.Error == nil && call.hook != nil {
		response.value = call.hook(message.Result)
	}
	call.done <- response
}

func (c *Client) handleNotification(method string, params json.RawMessage) {
	switch method {
	case "message":
		var notification struct {
			Subscription int64   `json:"subscription"`
			Message      Message `json:"message"`
		}
		if err := json.Unmarshal(params, &notification); err != nil {
			c.logger.Warn("ignoring invalid imsg message notification")
			return
		}
		c.deliver(notification.Subscription, notification.Message)
	case "watch.overflow":
		var notification struct {
			Subscription     int64  `json:"subscription"`
			ResumeAfterRowID int64  `json:"resume_after_rowid"`
			Reason           string `json:"reason"`
		}
		if err := json.Unmarshal(params, &notification); err != nil {
			return
		}
		c.mu.Lock()
		if sub := c.subs[notification.Subscription]; sub != nil {
			c.finishLocked(sub, &OverflowError{ResumeAfterRowID: notification.ResumeAfterRowID, Reason: notification.Reason})
		}
		c.mu.Unlock()
	case "error":
		// imsg ends a subscription with this notification when watching fails.
		var notification struct {
			Subscription int64 `json:"subscription"`
			Error        struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal(params, &notification); err != nil {
			return
		}
		c.mu.Lock()
		if sub := c.subs[notification.Subscription]; sub != nil {
			c.finishLocked(sub, fmt.Errorf("imsg watch failed: %s", safeError(errors.New(notification.Error.Message))))
		}
		c.mu.Unlock()
	}
}

func (c *Client) deliver(id int64, message Message) {
	c.mu.Lock()
	defer c.mu.Unlock()
	sub := c.subs[id]
	if sub == nil {
		return
	}
	select {
	case sub.messages <- message:
	default:
		// Never block the reader: send responses share this stream. The owner
		// resubscribes from its durable cursor, so nothing is lost.
		c.finishLocked(sub, ErrSlowConsumer)
		go c.unsubscribe(id)
	}
}

func (c *Client) unsubscribe(id int64) {
	ctx, cancel := context.WithTimeout(context.Background(), unsubscribeWait)
	defer cancel()
	_, _, _ = c.call(ctx, "watch.unsubscribe", map[string]any{"subscription": id}, nil)
}

func (c *Client) finishLocked(sub *Subscription, err error) {
	if sub.finished {
		return
	}
	sub.finished = true
	sub.err = err
	delete(c.subs, sub.id)
	close(sub.messages)
}

func (c *Client) shutdown(err error) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	c.err = err
	for id, call := range c.pending {
		call.done <- rpcResponse{transport: fmt.Errorf("%w: %w", ErrNoResponse, ErrClosed)}
		delete(c.pending, id)
	}
	for _, sub := range c.subs {
		c.finishLocked(sub, ErrClosed)
	}
	c.mu.Unlock()
	close(c.done)
}

// Subscription is one watch.subscribe stream.
type Subscription struct {
	id       int64
	client   *Client
	messages chan Message
	// finished and err are guarded by client.mu.
	finished bool
	err      error
}

// Messages yields new-row and mutation notifications. It is closed when the
// subscription ends; Err then reports why.
func (s *Subscription) Messages() <-chan Message { return s.messages }

// Err reports why the subscription ended, or nil while it is active.
func (s *Subscription) Err() error {
	s.client.mu.Lock()
	defer s.client.mu.Unlock()
	return s.err
}

// Close unsubscribes and ends the stream.
func (s *Subscription) Close() {
	s.client.mu.Lock()
	active := !s.finished
	s.client.finishLocked(s, ErrSubscriptionClosed)
	s.client.mu.Unlock()
	if active {
		s.client.unsubscribe(s.id)
	}
}

func logDiagnostics(stderr io.Reader, logger *slog.Logger) {
	scanner := bufio.NewScanner(stderr)
	scanner.Buffer(make([]byte, 4<<10), 64<<10)
	for scanner.Scan() {
		line := strings.Map(func(r rune) rune {
			if unicode.IsControl(r) {
				return -1
			}
			return r
		}, strings.TrimSpace(scanner.Text()))
		if len(line) > 512 {
			line = line[:512]
		}
		if line != "" {
			logger.Info("imsg diagnostic", "message", line)
		}
	}
}
