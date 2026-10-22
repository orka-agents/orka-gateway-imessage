// Package imessage normalizes Messages handles and chat GUIDs and holds the
// sender allowlist that bounds both inbound forwarding and outbound sends.
package imessage

import (
	"errors"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

const maxIdentityBytes = 256

// NormalizeHandle returns the canonical form of an iMessage/SMS handle: an
// E.164 phone number such as +14155551212, or a lowercase email address.
func NormalizeHandle(raw string) (string, error) {
	handle := strings.TrimSpace(raw)
	if handle == "" || len(handle) > maxIdentityBytes || !utf8.ValidString(handle) {
		return "", errors.New("handle is empty or too long")
	}
	if strings.Contains(handle, "@") {
		handle = strings.ToLower(handle)
		local, domain, ok := strings.Cut(handle, "@")
		if !ok || local == "" || domain == "" || strings.Contains(domain, "@") ||
			strings.ContainsFunc(handle, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }) {
			return "", errors.New("email handle is invalid")
		}
		return handle, nil
	}
	digits := strings.TrimPrefix(handle, "+")
	if digits == handle || len(digits) < 7 || len(digits) > 15 || strings.ContainsFunc(digits, func(r rune) bool { return r < '0' || r > '9' }) {
		return "", errors.New("phone handle must be E.164, for example +14155551212")
	}
	return handle, nil
}

// Allowlist is an immutable set of normalized handles.
type Allowlist struct {
	handles map[string]struct{}
}

// ParseAllowlist parses a comma-separated handle list. An empty list is an
// error: the adapter never forwards or sends without an explicit allowlist.
func ParseAllowlist(raw string) (Allowlist, error) {
	handles := map[string]struct{}{}
	for _, entry := range strings.Split(raw, ",") {
		if strings.TrimSpace(entry) == "" {
			continue
		}
		handle, err := NormalizeHandle(entry)
		if err != nil {
			return Allowlist{}, fmt.Errorf("allowlist entry %q: %w", strings.TrimSpace(entry), err)
		}
		handles[handle] = struct{}{}
	}
	if len(handles) == 0 {
		return Allowlist{}, errors.New("allowlist must contain at least one handle")
	}
	return Allowlist{handles: handles}, nil
}

// Contains reports whether raw normalizes to an allowlisted handle.
func (a Allowlist) Contains(raw string) bool {
	handle, err := NormalizeHandle(raw)
	if err != nil {
		return false
	}
	_, ok := a.handles[handle]
	return ok
}

// Len returns the number of distinct allowlisted handles.
func (a Allowlist) Len() int { return len(a.handles) }

// Chat is a parsed Messages chat GUID such as "iMessage;-;+14155551212"
// (direct) or "iMessage;+;chat123" (group).
type Chat struct {
	GUID    string
	Service string
	Group   bool
	// Identifier is the handle of a direct chat or the group identifier.
	Identifier string
}

// ParseChatGUID parses a chat GUID without consulting the Messages database.
func ParseChatGUID(guid string) (Chat, error) {
	if guid == "" || guid != strings.TrimSpace(guid) || len(guid) > maxIdentityBytes || !utf8.ValidString(guid) ||
		strings.ContainsFunc(guid, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }) {
		return Chat{}, errors.New("chat GUID is invalid")
	}
	parts := strings.SplitN(guid, ";", 3)
	if len(parts) != 3 || parts[0] == "" || parts[2] == "" || (parts[1] != "-" && parts[1] != "+") {
		return Chat{}, errors.New("chat GUID is invalid")
	}
	return Chat{GUID: guid, Service: parts[0], Group: parts[1] == "+", Identifier: parts[2]}, nil
}
