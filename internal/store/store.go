// Package store keeps the adapter's durable state in SQLite: the inbound
// watch cursor, chats admitted to Orka, and outbound delivery idempotency.
package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const (
	schemaVersion = 1

	// OutcomeUnknownMessage is recorded when a restart interrupts a send.
	OutcomeUnknownMessage = "iMessage delivery outcome is unknown after adapter restart"
)

var (
	// ErrDigestConflict means an idempotency ID was reused for a different request.
	ErrDigestConflict = errors.New("delivery idempotency conflict")
	// ErrInvalidTransition means a delivery result would overwrite another state.
	ErrInvalidTransition = errors.New("invalid delivery state transition")
)

// DeliveryState is the durable state of one outbound delivery.
type DeliveryState string

const (
	DeliverySending   DeliveryState = "sending"
	DeliveryRetryable DeliveryState = "retryable"
	DeliveryDelivered DeliveryState = "delivered"
	DeliveryPermanent DeliveryState = "permanent"
	// DeliveryUnknown is terminal: retrying an ambiguous send could duplicate it.
	DeliveryUnknown DeliveryState = "unknown"
)

// Terminal reports whether a delivery must be replayed rather than sent.
func (s DeliveryState) Terminal() bool {
	return s == DeliveryDelivered || s == DeliveryPermanent || s == DeliveryUnknown
}

// DeliveryRecord is the idempotency record for one logical Orka delivery.
type DeliveryRecord struct {
	IdempotencyID     string
	RequestDigest     string
	State             DeliveryState
	ProviderMessageID string
	SafeMessage       string
	ChatGUID          string
	TextDigest        string
	UpdatedAt         time.Time
}

// Store is safe for concurrent use. One database file belongs to one adapter
// process; opening it marks interrupted sends as unknown.
type Store struct {
	db *sql.DB
}

// Open opens or creates the database at path and recovers interrupted sends.
func Open(ctx context.Context, path string) (*Store, error) {
	path = strings.TrimSpace(path)
	if path == "" || path == ":memory:" || strings.HasPrefix(path, "file:") {
		return nil, errors.New("a filesystem database path is required")
	}
	absolute, err := filepath.Abs(filepath.Clean(path))
	if err != nil {
		return nil, fmt.Errorf("resolve database path: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(absolute), 0o700); err != nil {
		return nil, fmt.Errorf("create database directory: %w", err)
	}
	dsn := (&url.URL{Scheme: "file", Path: absolute, RawQuery: url.Values{
		"_pragma": {"busy_timeout(5000)", "foreign_keys(1)", "journal_mode(WAL)", "synchronous(FULL)"},
	}.Encode()}).String()
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite store: %w", err)
	}
	store := &Store{db: db}
	if err := store.init(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := os.Chmod(absolute, 0o600); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("restrict database permissions: %w", err)
	}
	return store, nil
}

func (s *Store) init(ctx context.Context) error {
	var version int
	if err := s.db.QueryRowContext(ctx, `PRAGMA user_version`).Scan(&version); err != nil {
		return fmt.Errorf("read schema version: %w", err)
	}
	switch version {
	case 0:
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return fmt.Errorf("create schema: %w", err)
		}
		defer func() { _ = tx.Rollback() }()
		if _, err := tx.ExecContext(ctx, `
			CREATE TABLE watch_cursor (
				id INTEGER PRIMARY KEY CHECK (id = 1),
				last_rowid INTEGER NOT NULL CHECK (last_rowid >= 0),
				updated_at_ms INTEGER NOT NULL
			);
			CREATE TABLE reply_chats (
				chat_guid TEXT PRIMARY KEY,
				first_seen_at_ms INTEGER NOT NULL,
				last_inbound_at_ms INTEGER NOT NULL
			);
			CREATE TABLE deliveries (
				idempotency_id TEXT PRIMARY KEY,
				request_digest TEXT NOT NULL,
				state TEXT NOT NULL CHECK (state IN ('sending','retryable','delivered','permanent','unknown')),
				provider_message_id TEXT NOT NULL DEFAULT '',
				safe_message TEXT NOT NULL DEFAULT '',
				chat_guid TEXT NOT NULL,
				text_digest TEXT NOT NULL,
				created_at_ms INTEGER NOT NULL,
				updated_at_ms INTEGER NOT NULL
			);
			CREATE INDEX deliveries_echo ON deliveries (chat_guid, text_digest, updated_at_ms);
			PRAGMA user_version = 1;`); err != nil {
			return fmt.Errorf("create schema: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("create schema: %w", err)
		}
	case schemaVersion:
	default:
		return fmt.Errorf("database schema version %d is newer than this adapter supports", version)
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE deliveries SET state = 'unknown', safe_message = ?, updated_at_ms = ?
		WHERE state = 'sending'`, OutcomeUnknownMessage, nowMillis()); err != nil {
		return fmt.Errorf("recover interrupted deliveries: %w", err)
	}
	return nil
}

// Close releases the database.
func (s *Store) Close() error { return s.db.Close() }

// Ping verifies the database can serve reads.
func (s *Store) Ping(ctx context.Context) error {
	var one int
	return s.db.QueryRowContext(ctx, `SELECT 1`).Scan(&one)
}

// Cursor returns the highest processed Messages row, or 0 before the first.
func (s *Store) Cursor(ctx context.Context) (int64, error) {
	var rowID int64
	err := s.db.QueryRowContext(ctx, `SELECT last_rowid FROM watch_cursor WHERE id = 1`).Scan(&rowID)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return rowID, err
}

// AdvanceCursor records rowID as processed. The cursor never moves backwards.
func (s *Store) AdvanceCursor(ctx context.Context, rowID int64) error {
	if rowID <= 0 {
		return errors.New("cursor row must be positive")
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO watch_cursor (id, last_rowid, updated_at_ms) VALUES (1, ?, ?)
		ON CONFLICT (id) DO UPDATE SET last_rowid = MAX(last_rowid, excluded.last_rowid), updated_at_ms = excluded.updated_at_ms`,
		rowID, nowMillis())
	return err
}

// RememberReplyChat records that an allowlisted inbound message arrived in chatGUID.
func (s *Store) RememberReplyChat(ctx context.Context, chatGUID string) error {
	now := nowMillis()
	_, err := s.db.ExecContext(ctx, `INSERT INTO reply_chats (chat_guid, first_seen_at_ms, last_inbound_at_ms) VALUES (?, ?, ?)
		ON CONFLICT (chat_guid) DO UPDATE SET last_inbound_at_ms = excluded.last_inbound_at_ms`, chatGUID, now, now)
	return err
}

// ReplyChatKnown reports whether chatGUID previously produced an admitted inbound message.
func (s *Store) ReplyChatKnown(ctx context.Context, chatGUID string) (bool, error) {
	var one int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM reply_chats WHERE chat_guid = ?`, chatGUID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// RecentlySent reports whether the adapter sent (or may have sent) text with
// textDigest to chatGUID since the given time. Self-chats echo outbound sends
// back as inbound rows; this lets the adapter drop them instead of looping.
func (s *Store) RecentlySent(ctx context.Context, chatGUID, textDigest string, since time.Time) (bool, error) {
	var one int
	err := s.db.QueryRowContext(ctx, `SELECT 1 FROM deliveries
		WHERE chat_guid = ? AND text_digest = ? AND state IN ('sending','delivered','unknown') AND updated_at_ms >= ?
		LIMIT 1`, chatGUID, textDigest, since.UnixMilli()).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// GetDelivery returns the record for idempotencyID, if any.
func (s *Store) GetDelivery(ctx context.Context, idempotencyID string) (DeliveryRecord, bool, error) {
	record, err := scanDelivery(s.db.QueryRowContext(ctx, deliverySelect+` WHERE idempotency_id = ?`, idempotencyID))
	if errors.Is(err, sql.ErrNoRows) {
		return DeliveryRecord{}, false, nil
	}
	return record, err == nil, err
}

// ClaimDelivery atomically creates a sending record or reclaims a retryable
// one. shouldSend is false for terminal and in-flight records, which callers
// replay instead of sending again.
func (s *Store) ClaimDelivery(ctx context.Context, idempotencyID, requestDigest, chatGUID, textDigest string) (DeliveryRecord, bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return DeliveryRecord{}, false, err
	}
	defer func() { _ = tx.Rollback() }()
	now := nowMillis()
	record, err := scanDelivery(tx.QueryRowContext(ctx, deliverySelect+` WHERE idempotency_id = ?`, idempotencyID))
	switch {
	case errors.Is(err, sql.ErrNoRows):
		if _, err := tx.ExecContext(ctx, `INSERT INTO deliveries
			(idempotency_id, request_digest, state, chat_guid, text_digest, created_at_ms, updated_at_ms)
			VALUES (?, ?, 'sending', ?, ?, ?, ?)`, idempotencyID, requestDigest, chatGUID, textDigest, now, now); err != nil {
			return DeliveryRecord{}, false, err
		}
		record = DeliveryRecord{IdempotencyID: idempotencyID, RequestDigest: requestDigest, State: DeliverySending,
			ChatGUID: chatGUID, TextDigest: textDigest, UpdatedAt: time.UnixMilli(now).UTC()}
	case err != nil:
		return DeliveryRecord{}, false, err
	case record.RequestDigest != requestDigest:
		return DeliveryRecord{}, false, ErrDigestConflict
	case record.State != DeliveryRetryable:
		return record, false, nil
	default:
		if _, err := tx.ExecContext(ctx, `UPDATE deliveries SET state = 'sending', provider_message_id = '', safe_message = '',
			updated_at_ms = ? WHERE idempotency_id = ? AND state = 'retryable'`, now, idempotencyID); err != nil {
			return DeliveryRecord{}, false, err
		}
		record.State, record.ProviderMessageID, record.SafeMessage = DeliverySending, "", ""
		record.UpdatedAt = time.UnixMilli(now).UTC()
	}
	if err := tx.Commit(); err != nil {
		return DeliveryRecord{}, false, err
	}
	return record, true, nil
}

// FinishDelivery records the outcome of a claimed send.
func (s *Store) FinishDelivery(ctx context.Context, idempotencyID, requestDigest string, state DeliveryState, providerMessageID, safeMessage string) (DeliveryRecord, error) {
	if state == DeliverySending {
		return DeliveryRecord{}, ErrInvalidTransition
	}
	result, err := s.db.ExecContext(ctx, `UPDATE deliveries SET state = ?, provider_message_id = ?, safe_message = ?, updated_at_ms = ?
		WHERE idempotency_id = ? AND request_digest = ? AND state = 'sending'`,
		string(state), providerMessageID, safeMessage, nowMillis(), idempotencyID, requestDigest)
	if err != nil {
		return DeliveryRecord{}, err
	}
	if changed, err := result.RowsAffected(); err != nil || changed != 1 {
		return DeliveryRecord{}, ErrInvalidTransition
	}
	record, _, err := s.GetDelivery(ctx, idempotencyID)
	return record, err
}

const deliverySelect = `SELECT idempotency_id, request_digest, state, provider_message_id, safe_message, chat_guid, text_digest, updated_at_ms FROM deliveries`

type rowScanner interface{ Scan(...any) error }

func scanDelivery(row rowScanner) (DeliveryRecord, error) {
	var record DeliveryRecord
	var state string
	var updated int64
	if err := row.Scan(&record.IdempotencyID, &record.RequestDigest, &state, &record.ProviderMessageID,
		&record.SafeMessage, &record.ChatGUID, &record.TextDigest, &updated); err != nil {
		return DeliveryRecord{}, err
	}
	record.State = DeliveryState(state)
	record.UpdatedAt = time.UnixMilli(updated).UTC()
	return record, nil
}

// Digest returns a hex SHA-256 digest.
func Digest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// TextDigest digests message text after normalizing line endings and edges,
// so an echoed send matches the text the adapter sent.
func TextDigest(text string) string {
	return Digest([]byte(strings.TrimSpace(strings.ReplaceAll(text, "\r\n", "\n"))))
}

func nowMillis() int64 { return time.Now().UnixMilli() }
