// Package imsg supervises an `imsg rpc` child process and speaks its
// line-delimited JSON-RPC 2.0 protocol over stdio.
package imsg

import (
	"encoding/json"
	"errors"
	"fmt"
)

// JSON-RPC error codes returned by imsg rpc.
const (
	CodeParseError          = -32700
	CodeInvalidRequest      = -32600
	CodeMethodNotFound      = -32601
	CodeInvalidParams       = -32602
	CodeInternal            = -32603
	CodeServerBusy          = -32000
	CodeOutcomeUnknown      = -32001
	CodeDatabaseUnavailable = -32002
	CodeBridgeUnavailable   = -32003
	CodeMutationLaneBlocked = -32004
)

var (
	// ErrNotDispatched means a request never reached the imsg child, so a
	// send can be retried without risking a duplicate.
	ErrNotDispatched = errors.New("imsg request was not dispatched")
	// ErrNoResponse means a request was written but no usable response
	// arrived; a send may or may not have happened.
	ErrNoResponse = errors.New("imsg response was not received")
	// ErrClosed means the imsg child is not running.
	ErrClosed = errors.New("imsg rpc child is not running")
	// ErrSlowConsumer ends a subscription whose reader fell behind.
	ErrSlowConsumer = errors.New("imsg subscription consumer fell behind")
	// ErrSubscriptionClosed ends a subscription closed by its owner.
	ErrSubscriptionClosed = errors.New("imsg subscription closed")
)

// RPCError is a JSON-RPC error object.
type RPCError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (e *RPCError) Error() string {
	return fmt.Sprintf("imsg rpc error %d: %s", e.Code, e.Message)
}

// RetrySafe returns the structured retry_safe flag imsg attaches to delivery
// failures. known is false when the error carries no such flag.
func (e *RPCError) RetrySafe() (safe, known bool) {
	var data struct {
		RetrySafe *bool `json:"retry_safe"`
	}
	if len(e.Data) == 0 || json.Unmarshal(e.Data, &data) != nil || data.RetrySafe == nil {
		return false, false
	}
	return *data.RetrySafe, true
}

// OverflowError ends a subscription after imsg reported watch.overflow.
type OverflowError struct {
	ResumeAfterRowID int64
	Reason           string
}

func (e *OverflowError) Error() string {
	return fmt.Sprintf("imsg watch overflow (%s) after row %d", e.Reason, e.ResumeAfterRowID)
}

// Status is the readiness snapshot returned by initialize and status.
type Status struct {
	Version         string `json:"version"`
	ProtocolVersion int    `json:"protocol_version"`
	Database        struct {
		Path  string `json:"path"`
		Ready bool   `json:"ready"`
		Error string `json:"error"`
	} `json:"database"`
}

// Message is the subset of the imsg message object the adapter uses.
type Message struct {
	ID              int64           `json:"id"`
	ChatID          int64           `json:"chat_id"`
	ChatIdentifier  string          `json:"chat_identifier"`
	ChatGUID        string          `json:"chat_guid"`
	IsGroup         bool            `json:"is_group"`
	GUID            string          `json:"guid"`
	Sender          string          `json:"sender"`
	SenderName      string          `json:"sender_name"`
	IsFromMe        bool            `json:"is_from_me"`
	Text            string          `json:"text"`
	CreatedAt       string          `json:"created_at"`
	Type            string          `json:"type"`
	IsReaction      bool            `json:"is_reaction"`
	BalloonBundleID string          `json:"balloon_bundle_id"`
	Poll            json.RawMessage `json:"poll"`
}

// SendResult is the imsg send acknowledgement.
type SendResult struct {
	OK        bool   `json:"ok"`
	ID        int64  `json:"id"`
	GUID      string `json:"guid"`
	Transport string `json:"transport"`
	ChatGUID  string `json:"chat_guid"`
	Service   string `json:"service"`
}
