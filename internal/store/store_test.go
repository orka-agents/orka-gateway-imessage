package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func openTest(t *testing.T, path string) *Store {
	t.Helper()
	database, err := Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	return database
}

func TestCursorIsMonotonicAndDurable(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "nested", "adapter.db")
	database := openTest(t, path)
	if cursor, initialized, err := database.Cursor(ctx); err != nil || cursor != 0 || initialized {
		t.Fatalf("initial cursor = %d, %v, %v", cursor, initialized, err)
	}
	if err := database.InitializeCursor(ctx, 5); err != nil {
		t.Fatal(err)
	}
	if err := database.InitializeCursor(ctx, 9); err != nil {
		t.Fatal(err)
	}
	if cursor, initialized, err := database.Cursor(ctx); err != nil || cursor != 5 || !initialized {
		t.Fatalf("initialized cursor = %d, %v, %v", cursor, initialized, err)
	}
	for _, rowID := range []int64{10, 7, 12} {
		if err := database.AdvanceCursor(ctx, rowID); err != nil {
			t.Fatal(err)
		}
	}
	if err := database.AdvanceCursor(ctx, 0); err == nil {
		t.Fatal("non-positive cursor must be rejected")
	}
	_ = database.Close()
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("database mode = %v, %v", info.Mode().Perm(), err)
	}
	reopened := openTest(t, path)
	if cursor, _, err := reopened.Cursor(ctx); err != nil || cursor != 12 {
		t.Fatalf("reopened cursor = %d, %v", cursor, err)
	}
}

func TestEmptyDatabaseCursorIsInitialized(t *testing.T) {
	ctx := context.Background()
	database := openTest(t, filepath.Join(t.TempDir(), "adapter.db"))
	if err := database.InitializeCursor(ctx, 0); err != nil {
		t.Fatal(err)
	}
	if cursor, initialized, err := database.Cursor(ctx); err != nil || cursor != 0 || !initialized {
		t.Fatalf("cursor = %d, %v, %v", cursor, initialized, err)
	}
	if err := database.InitializeCursor(ctx, -1); err == nil {
		t.Fatal("negative initial cursor accepted")
	}
}

func TestReplyChats(t *testing.T) {
	ctx := context.Background()
	database := openTest(t, filepath.Join(t.TempDir(), "adapter.db"))
	if known, err := database.ReplyChatKnown(ctx, "iMessage;-;+14155551212"); err != nil || known {
		t.Fatalf("unknown chat = %v, %v", known, err)
	}
	for range 2 {
		if err := database.RememberReplyChat(ctx, "iMessage;-;+14155551212"); err != nil {
			t.Fatal(err)
		}
	}
	if known, err := database.ReplyChatKnown(ctx, "iMessage;-;+14155551212"); err != nil || !known {
		t.Fatalf("remembered chat = %v, %v", known, err)
	}
}

func TestDeliveryLifecycle(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "adapter.db")
	database := openTest(t, path)
	chat, text := "iMessage;-;+14155551212", TextDigest("hello")

	record, send, err := database.ClaimDelivery(ctx, "d1", "digest", chat, text)
	if err != nil || !send || record.State != DeliverySending {
		t.Fatalf("first claim = %+v, %v, %v", record, send, err)
	}
	if _, send, err := database.ClaimDelivery(ctx, "d1", "digest", chat, text); err != nil || send {
		t.Fatalf("claim while sending = %v, %v", send, err)
	}
	if _, _, err := database.ClaimDelivery(ctx, "d1", "other", chat, text); !errors.Is(err, ErrDigestConflict) {
		t.Fatalf("conflicting claim = %v", err)
	}
	if _, err := database.FinishDelivery(ctx, "d1", "digest", DeliveryRetryable, "", "busy"); err != nil {
		t.Fatal(err)
	}
	if _, send, err := database.ClaimDelivery(ctx, "d1", "digest", chat, text); err != nil || !send {
		t.Fatalf("retryable reclaim = %v, %v", send, err)
	}
	finished, err := database.FinishDelivery(ctx, "d1", "digest", DeliveryDelivered, "GUID-1", "")
	if err != nil || finished.State != DeliveryDelivered || finished.ProviderMessageID != "GUID-1" {
		t.Fatalf("finish = %+v, %v", finished, err)
	}
	if _, err := database.FinishDelivery(ctx, "d1", "digest", DeliveryPermanent, "", ""); !errors.Is(err, ErrInvalidTransition) {
		t.Fatalf("overwrite terminal = %v", err)
	}
	if replayed, send, err := database.ClaimDelivery(ctx, "d1", "digest", chat, text); err != nil || send || replayed.ProviderMessageID != "GUID-1" {
		t.Fatalf("terminal replay = %+v, %v, %v", replayed, send, err)
	}

	if _, _, err := database.ClaimDelivery(ctx, "d2", "digest2", chat, TextDigest("other")); err != nil {
		t.Fatal(err)
	}
	_ = database.Close()
	reopened := openTest(t, path)
	interrupted, found, err := reopened.GetDelivery(ctx, "d2")
	if err != nil || !found || interrupted.State != DeliveryUnknown || interrupted.SafeMessage != OutcomeUnknownMessage {
		t.Fatalf("interrupted send after restart = %+v, %v, %v", interrupted, found, err)
	}
	if _, send, err := reopened.ClaimDelivery(ctx, "d2", "digest2", chat, TextDigest("other")); err != nil || send {
		t.Fatalf("unknown delivery must never resend: %v, %v", send, err)
	}
}

func TestSentNear(t *testing.T) {
	ctx := context.Background()
	database := openTest(t, filepath.Join(t.TempDir(), "adapter.db"))
	chat := "iMessage;-;me@example.com"
	window := 2 * time.Minute
	if _, _, err := database.ClaimDelivery(ctx, "d1", "digest", chat, TextDigest("hello\r\n")); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	if echo, err := database.SentNear(ctx, chat, TextDigest(" hello\n"), now, window); err != nil || !echo {
		t.Fatalf("in-flight echo = %v, %v", echo, err)
	}
	if _, err := database.FinishDelivery(ctx, "d1", "digest", DeliveryPermanent, "", "rejected"); err != nil {
		t.Fatal(err)
	}
	if echo, err := database.SentNear(ctx, chat, TextDigest("hello"), now, window); err != nil || echo {
		t.Fatalf("rejected send must not suppress inbound text: %v, %v", echo, err)
	}
	if _, _, err := database.ClaimDelivery(ctx, "d2", "digest2", chat, TextDigest("bye")); err != nil {
		t.Fatal(err)
	}
	if _, err := database.FinishDelivery(ctx, "d2", "digest2", DeliveryDelivered, "G", ""); err != nil {
		t.Fatal(err)
	}
	sent := time.Now()
	// The match depends on the inbound row's time, not on when it is processed.
	if echo, err := database.SentNear(ctx, chat, TextDigest("bye"), sent, window); err != nil || !echo {
		t.Fatalf("delivered echo = %v, %v", echo, err)
	}
	for name, check := range map[string]func() (bool, error){
		"other chat": func() (bool, error) {
			return database.SentNear(ctx, "iMessage;-;+1415", TextDigest("bye"), sent, window)
		},
		"other text": func() (bool, error) { return database.SentNear(ctx, chat, TextDigest("bye!"), sent, window) },
		"row long after send": func() (bool, error) {
			return database.SentNear(ctx, chat, TextDigest("bye"), sent.Add(time.Hour), window)
		},
		"row long before send": func() (bool, error) {
			return database.SentNear(ctx, chat, TextDigest("bye"), sent.Add(-time.Hour), window)
		},
	} {
		if echo, err := check(); err != nil || echo {
			t.Errorf("%s: echo = %v, %v", name, echo, err)
		}
	}
}

func TestRecordInbound(t *testing.T) {
	ctx := context.Background()
	database := openTest(t, filepath.Join(t.TempDir(), "adapter.db"))
	chat, text, at, window := "any;-;+14155551212", TextDigest("hi"), time.Now(), 10*time.Second
	for _, tc := range []struct {
		guid, chat, text string
		at               time.Time
		duplicate        bool
	}{
		{"A", chat, text, at, false},
		{"A", chat, text, at, false},
		{"B", chat, text, at.Add(2 * time.Second), true},
		{"C", chat, TextDigest("other"), at, false},
		{"D", "any;-;me@example.com", text, at, false},
		{"E", chat, text, at.Add(time.Minute), false},
	} {
		duplicate, err := database.RecordInbound(ctx, tc.guid, tc.chat, tc.text, tc.at, window)
		if err != nil || duplicate != tc.duplicate {
			t.Fatalf("%s: duplicate = %v, %v; want %v", tc.guid, duplicate, err, tc.duplicate)
		}
	}
}
