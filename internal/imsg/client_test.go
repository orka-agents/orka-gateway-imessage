package imsg

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"
)

type fakeRequest struct {
	ID     int64           `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

// fakeChild runs handler for each request the client writes. handler writes
// response and notification lines with write; close ends the child's stdout.
type fakeChild struct {
	writeMu sync.Mutex
	out     *io.PipeWriter
	in      *io.PipeReader
	done    chan struct{}
	mu      sync.Mutex
	methods []string
}

func (f *fakeChild) write(line string) {
	f.writeMu.Lock()
	defer f.writeMu.Unlock()
	_, _ = f.out.Write([]byte(line + "\n"))
}

func (f *fakeChild) close() {
	_ = f.out.Close()
	_ = f.in.Close()
}

func (f *fakeChild) seen() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.methods...)
}

func newFakeClient(t *testing.T, handler func(*fakeChild, fakeRequest)) (*Client, *fakeChild) {
	t.Helper()
	requestsR, requestsW := io.Pipe()
	outputR, outputW := io.Pipe()
	child := &fakeChild{out: outputW, in: requestsR, done: make(chan struct{})}
	go func() {
		defer close(child.done)
		scanner := bufio.NewScanner(requestsR)
		for scanner.Scan() {
			var request fakeRequest
			if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
				t.Errorf("invalid request: %v", err)
				continue
			}
			child.mu.Lock()
			child.methods = append(child.methods, request.Method)
			child.mu.Unlock()
			handler(child, request)
		}
		_ = outputW.Close()
	}()
	client := newClient(requestsW, outputR, child.close, func() error { return nil }, slog.New(slog.DiscardHandler))
	t.Cleanup(func() {
		child.close()
		<-client.Done()
	})
	return client, child
}

func result(id int64, value string) string {
	return fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"result":%s}`, id, value)
}

func TestSendResultAndRPCError(t *testing.T) {
	client, _ := newFakeClient(t, func(child *fakeChild, request fakeRequest) {
		var params map[string]any
		_ = json.Unmarshal(request.Params, &params)
		switch params["text"] {
		case "ok":
			if params["chat_guid"] != "iMessage;-;+14155551212" || len(params) != 2 {
				t.Errorf("unexpected send params: %v", params)
			}
			child.write(result(request.ID, `{"ok":true,"transport":"applescript","id":7,"guid":"GUID-7","message_id":"GUID-7"}`))
		case "unknown":
			child.write(fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"error":{"code":-32001,"message":"Delivery outcome unknown","data":{"retry_safe":false,"disposition":"may_have_completed"}}}`, request.ID))
		default:
			child.write(fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"error":{"code":-32602,"message":"Invalid params","data":"unknown chat"}}`, request.ID))
		}
	})
	ctx := context.Background()
	sent, err := client.Send(ctx, "iMessage;-;+14155551212", "ok")
	if err != nil || !sent.OK || sent.GUID != "GUID-7" || sent.ID != 7 {
		t.Fatalf("Send = %+v, %v", sent, err)
	}
	_, err = client.Send(ctx, "iMessage;-;+14155551212", "unknown")
	var rpcErr *RPCError
	if !errors.As(err, &rpcErr) || rpcErr.Code != CodeOutcomeUnknown {
		t.Fatalf("expected outcome-unknown RPC error, got %v", err)
	}
	if safe, known := rpcErr.RetrySafe(); safe || !known {
		t.Fatalf("RetrySafe = %v, %v", safe, known)
	}
	_, err = client.Send(ctx, "iMessage;-;+14155551212", "bad")
	if !errors.As(err, &rpcErr) || rpcErr.Code != CodeInvalidParams {
		t.Fatalf("expected invalid-params RPC error, got %v", err)
	}
	if _, known := rpcErr.RetrySafe(); known {
		t.Fatal("string error data must not report retry safety")
	}
}

func TestSubscribeReceivesNotificationWrittenRightAfterResponse(t *testing.T) {
	client, _ := newFakeClient(t, func(child *fakeChild, request fakeRequest) {
		if request.Method == "watch.subscribe" {
			if string(request.Params) != `{"since_rowid":41}` {
				t.Errorf("subscribe params = %s", request.Params)
			}
			child.write(result(request.ID, `{"subscription":3,"buffer_limit":256}`))
			child.write(`{"jsonrpc":"2.0","method":"message","params":{"subscription":3,"message":{"id":42,"guid":"G42","chat_guid":"iMessage;-;+14155551212","sender":"+14155551212","text":"hi","is_from_me":false,"created_at":"2026-10-22T07:00:00Z"}}}`)
			child.write(`{"jsonrpc":"2.0","method":"message","params":{"subscription":99,"message":{"id":43}}}`)
			child.write(`{"jsonrpc":"2.0","method":"watch.overflow","params":{"subscription":3,"resume_after_rowid":42,"reason":"buffer_limit_exceeded","terminal":true}}`)
		}
	})
	sub, err := client.Subscribe(context.Background(), 41)
	if err != nil {
		t.Fatal(err)
	}
	message, ok := <-sub.Messages()
	if !ok || message.ID != 42 || message.Text != "hi" || message.Sender != "+14155551212" {
		t.Fatalf("message = %+v, %v", message, ok)
	}
	if _, ok := <-sub.Messages(); ok {
		t.Fatal("subscription should end after overflow")
	}
	var overflow *OverflowError
	if !errors.As(sub.Err(), &overflow) || overflow.ResumeAfterRowID != 42 {
		t.Fatalf("Err = %v", sub.Err())
	}
}

func TestSubscribeFromTailOmitsCursor(t *testing.T) {
	client, _ := newFakeClient(t, func(child *fakeChild, request fakeRequest) {
		if string(request.Params) != `{}` {
			t.Errorf("tail subscribe params = %s", request.Params)
		}
		child.write(result(request.ID, `{"subscription":1}`))
	})
	if _, err := client.Subscribe(context.Background(), 0); err != nil {
		t.Fatal(err)
	}
}

func TestSlowConsumerDoesNotBlockResponses(t *testing.T) {
	unsubscribed := make(chan struct{}, 1)
	client, _ := newFakeClient(t, func(child *fakeChild, request fakeRequest) {
		switch request.Method {
		case "watch.subscribe":
			child.write(result(request.ID, `{"subscription":5}`))
			for i := 1; i <= eventBuffer+5; i++ {
				child.write(fmt.Sprintf(`{"jsonrpc":"2.0","method":"message","params":{"subscription":5,"message":{"id":%d}}}`, i))
			}
		case "watch.unsubscribe":
			unsubscribed <- struct{}{}
			child.write(result(request.ID, `{"ok":true}`))
		case "status":
			child.write(result(request.ID, `{"version":"test"}`))
		}
	})
	sub, err := client.Subscribe(context.Background(), 0)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var status Status
	if err := client.Call(ctx, "status", nil, &status); err != nil || status.Version != "test" {
		t.Fatalf("status call blocked behind a slow subscriber: %+v, %v", status, err)
	}
	select {
	case <-unsubscribed:
	case <-ctx.Done():
		t.Fatal("slow subscription was not unsubscribed")
	}
	count := 0
	for range sub.Messages() {
		count++
	}
	if count != eventBuffer || !errors.Is(sub.Err(), ErrSlowConsumer) {
		t.Fatalf("drained %d messages, Err = %v", count, sub.Err())
	}
}

func TestChildExitMakesWrittenRequestsUnknownAndLaterRequestsUndispatched(t *testing.T) {
	received := make(chan struct{})
	client, child := newFakeClient(t, func(_ *fakeChild, request fakeRequest) {
		if request.Method == "send" {
			close(received)
		}
	})
	errs := make(chan error, 1)
	go func() {
		_, err := client.Send(context.Background(), "iMessage;-;+14155551212", "hi")
		errs <- err
	}()
	<-received
	child.close()
	if err := <-errs; !errors.Is(err, ErrNoResponse) {
		t.Fatalf("in-flight send error = %v; want ErrNoResponse", err)
	}
	<-client.Done()
	if _, err := client.Send(context.Background(), "iMessage;-;+14155551212", "hi"); !errors.Is(err, ErrNotDispatched) {
		t.Fatalf("send after exit = %v; want ErrNotDispatched", err)
	}
}

func TestContextCancelAfterWriteIsNoResponse(t *testing.T) {
	client, _ := newFakeClient(t, func(*fakeChild, fakeRequest) {})
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := client.Send(ctx, "iMessage;-;+14155551212", "hi"); !errors.Is(err, ErrNoResponse) {
		t.Fatalf("Send = %v; want ErrNoResponse", err)
	}
}

func TestChildEnvironmentDropsAdapterSettings(t *testing.T) {
	env := ChildEnvironment([]string{"HOME=/Users/me", "ORKA_GATEWAY_INBOUND_TOKEN=secret", "ORKA_GATEWAY_OUTBOUND_TOKEN_FILE=/x", "PATH=/bin"})
	if len(env) != 2 || env[0] != "HOME=/Users/me" || env[1] != "PATH=/bin" {
		t.Fatalf("ChildEnvironment = %v", env)
	}
}

func TestSupervisorRestartsAfterBlockedMutationLane(t *testing.T) {
	starts := 0
	supervisor := NewSupervisor(Options{Logger: slog.New(slog.DiscardHandler)})
	supervisor.start = func(context.Context, Options) (*Client, error) {
		starts++
		blocked := starts == 1
		client, _ := newFakeClient(t, func(child *fakeChild, request fakeRequest) {
			if blocked {
				child.write(fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"error":{"code":-32004,"message":"Mutation lane blocked","data":{"retry_safe":true}}}`, request.ID))
				return
			}
			child.write(result(request.ID, `{"ok":true,"guid":"G"}`))
		})
		return client, nil
	}
	defer supervisor.Close()
	_, err := supervisor.Send(context.Background(), "iMessage;-;+14155551212", "hi")
	var rpcErr *RPCError
	if !errors.As(err, &rpcErr) || rpcErr.Code != CodeMutationLaneBlocked {
		t.Fatalf("first send = %v", err)
	}
	sent, err := supervisor.Send(context.Background(), "iMessage;-;+14155551212", "hi")
	if err != nil || sent.GUID != "G" || starts != 2 {
		t.Fatalf("second send = %+v, %v after %d starts", sent, err, starts)
	}
}

func TestSupervisorBacksOffAfterStartFailure(t *testing.T) {
	supervisor := NewSupervisor(Options{Logger: slog.New(slog.DiscardHandler)})
	starts := 0
	supervisor.start = func(context.Context, Options) (*Client, error) {
		starts++
		return nil, errors.New("no imsg")
	}
	for range 3 {
		if _, err := supervisor.Send(context.Background(), "iMessage;-;+1", "hi"); !errors.Is(err, ErrNotDispatched) {
			t.Fatalf("Send = %v; want ErrNotDispatched", err)
		}
	}
	if starts != 1 {
		t.Fatalf("start attempts during backoff = %d; want 1", starts)
	}
}

func TestErrorNotificationEndsSubscription(t *testing.T) {
	client, _ := newFakeClient(t, func(child *fakeChild, request fakeRequest) {
		child.write(result(request.ID, `{"subscription":2}`))
		child.write(`{"jsonrpc":"2.0","method":"error","params":{"subscription":2,"error":{"message":"database unavailable"}}}`)
	})
	sub, err := client.Subscribe(context.Background(), -5)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := <-sub.Messages(); ok {
		t.Fatal("subscription should end after an error notification")
	}
	if err := sub.Err(); err == nil || err.Error() != "imsg watch failed: database unavailable" {
		t.Fatalf("Err = %v", err)
	}
}

func TestSubscribeReplayFromFirstRow(t *testing.T) {
	client, _ := newFakeClient(t, func(child *fakeChild, request fakeRequest) {
		if string(request.Params) != `{"since_rowid":-1}` {
			t.Errorf("replay subscribe params = %s", request.Params)
		}
		child.write(result(request.ID, `{"subscription":1}`))
	})
	if _, err := client.Subscribe(context.Background(), -1); err != nil {
		t.Fatal(err)
	}
}

func TestLatestRowID(t *testing.T) {
	for _, rows := range [][]int64{nil, {1}, {3, 7}, {5, 1024, 1025}, {2, 9, 4096, 70001}} {
		var calls int
		client, _ := newFakeClient(t, func(child *fakeChild, request fakeRequest) {
			var params struct {
				SinceRowID       int64 `json:"since_rowid"`
				Limit            int   `json:"limit"`
				IncludeReactions bool  `json:"include_reactions"`
			}
			_ = json.Unmarshal(request.Params, &params)
			if request.Method != "messages.after" || params.Limit != 1 || !params.IncludeReactions {
				t.Errorf("unexpected probe %s %s", request.Method, request.Params)
			}
			calls++
			next, messages := params.SinceRowID, "[]"
			for _, row := range rows {
				if row > params.SinceRowID {
					next, messages = row, fmt.Sprintf(`[{"id":%d}]`, row)
					break
				}
			}
			child.write(result(request.ID, fmt.Sprintf(`{"messages":%s,"next_rowid":%d,"has_more":false}`, messages, next)))
		})
		got, err := client.LatestRowID(context.Background())
		want := int64(0)
		if len(rows) > 0 {
			want = rows[len(rows)-1]
		}
		if err != nil || got != want {
			t.Fatalf("rows %v: LatestRowID = %d, %v; want %d", rows, got, err, want)
		}
		if calls > 40 {
			t.Fatalf("rows %v: %d probes", rows, calls)
		}
	}
}
