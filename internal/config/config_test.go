package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func setRequired(t *testing.T) {
	t.Helper()
	t.Setenv("IMESSAGE_ACCOUNT_ID", "mac-messages")
	t.Setenv("IMESSAGE_ALLOWED_SENDERS", "+14155551212, Me@Example.com")
	t.Setenv("ORKA_GATEWAY_INGRESS_URL", "http://127.0.0.1:8081/api/v1/gateways/orka/imessage/events")
	t.Setenv("ORKA_GATEWAY_INBOUND_TOKEN", "inbound")
	t.Setenv("ORKA_GATEWAY_OUTBOUND_TOKEN", "outbound")
}

func TestLoadDefaults(t *testing.T) {
	setRequired(t)
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ListenAddress != "127.0.0.1:8787" || cfg.IMSGPath != "imsg" ||
		cfg.SendTimeout != time.Minute || cfg.Allowlist.Len() != 2 ||
		!strings.HasSuffix(cfg.DatabasePath, filepath.Join("orka-gateway-imessage", "adapter.db")) {
		t.Fatalf("defaults = %+v", cfg)
	}
}

func TestLoadRequiresAllowlistAndDistinctTokens(t *testing.T) {
	for name, env := range map[string][2]string{
		"empty allowlist": {"IMESSAGE_ALLOWED_SENDERS", ""},
		"local phone":     {"IMESSAGE_ALLOWED_SENDERS", "4155551212"},
		"no account":      {"IMESSAGE_ACCOUNT_ID", ""},
		"same tokens":     {"ORKA_GATEWAY_OUTBOUND_TOKEN", "inbound"},
		"bad timeout":     {"SEND_TIMEOUT", "-1s"},
		"bad log level":   {"LOG_LEVEL", "loud"},
	} {
		t.Run(name, func(t *testing.T) {
			setRequired(t)
			t.Setenv(env[0], env[1])
			if _, err := Load(); err == nil {
				t.Fatal("Load succeeded")
			}
		})
	}
}

func TestSecretFiles(t *testing.T) {
	setRequired(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "inbound")
	if err := os.WriteFile(path, []byte("from-file\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ORKA_GATEWAY_INBOUND_TOKEN", "")
	t.Setenv("ORKA_GATEWAY_INBOUND_TOKEN_FILE", path)
	cfg, err := Load()
	if err != nil || cfg.OrkaInboundToken != "from-file" {
		t.Fatalf("token from file = %q, %v", cfg.OrkaInboundToken, err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(); err == nil {
		t.Fatal("world-readable secret file was accepted")
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ORKA_GATEWAY_INBOUND_TOKEN", "inline")
	if _, err := Load(); err == nil {
		t.Fatal("value and file together were accepted")
	}
}
