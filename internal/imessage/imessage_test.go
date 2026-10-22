package imessage

import "testing"

func TestNormalizeHandle(t *testing.T) {
	for raw, want := range map[string]string{
		"+14155551212":        "+14155551212",
		" +14155551212 ":      "+14155551212",
		"User@Example.COM":    "user@example.com",
		"someone@icloud.com ": "someone@icloud.com",
	} {
		got, err := NormalizeHandle(raw)
		if err != nil || got != want {
			t.Errorf("NormalizeHandle(%q) = %q, %v; want %q", raw, got, err, want)
		}
	}
	for _, raw := range []string{"", "4155551212", "+1415", "+1415555121212345", "+1-415-555", "a@", "@b", "a@b@c", "a b@c"} {
		if got, err := NormalizeHandle(raw); err == nil {
			t.Errorf("NormalizeHandle(%q) = %q; want error", raw, got)
		}
	}
}

func TestAllowlist(t *testing.T) {
	if _, err := ParseAllowlist(" , "); err == nil {
		t.Fatal("empty allowlist must be rejected")
	}
	if _, err := ParseAllowlist("+14155551212,4155551213"); err == nil {
		t.Fatal("non-E.164 entry must be rejected")
	}
	list, err := ParseAllowlist("+14155551212, Me@Example.com,+14155551212")
	if err != nil {
		t.Fatal(err)
	}
	if list.Len() != 2 {
		t.Fatalf("Len = %d; want 2", list.Len())
	}
	for _, handle := range []string{"+14155551212", "me@example.com", "ME@EXAMPLE.COM"} {
		if !list.Contains(handle) {
			t.Errorf("Contains(%q) = false", handle)
		}
	}
	for _, handle := range []string{"+14155551213", "other@example.com", "", "14155551212"} {
		if list.Contains(handle) {
			t.Errorf("Contains(%q) = true", handle)
		}
	}
}

func TestParseChatGUID(t *testing.T) {
	direct, err := ParseChatGUID("iMessage;-;+14155551212")
	if err != nil || direct.Group || direct.Service != "iMessage" || direct.Identifier != "+14155551212" {
		t.Fatalf("direct = %+v, %v", direct, err)
	}
	group, err := ParseChatGUID("any;+;chat123456")
	if err != nil || !group.Group || group.Identifier != "chat123456" {
		t.Fatalf("group = %+v, %v", group, err)
	}
	for _, guid := range []string{"", "iMessage", "iMessage;-", "iMessage;x;+1", ";-;+1", "iMessage;-;", " iMessage;-;+1", "iMessage;-;a b"} {
		if _, err := ParseChatGUID(guid); err == nil {
			t.Errorf("ParseChatGUID(%q) succeeded", guid)
		}
	}
}
