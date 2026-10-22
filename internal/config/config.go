// Package config loads adapter settings from the environment.
package config

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/orka-agents/orka-gateway-imessage/internal/imessage"
)

type Config struct {
	ListenAddress       string
	DatabasePath        string
	IMSGPath            string
	IMSGDatabasePath    string
	AccountID           string
	Allowlist           imessage.Allowlist
	ConformanceChatGUID string
	OrkaIngressURL      string
	OrkaInboundToken    string
	OrkaOutboundToken   string
	RequestTimeout      time.Duration
	SendTimeout         time.Duration
	ShutdownTimeout     time.Duration
	LogLevel            slog.Level
	AdapterVersion      string
}

// Load reads and validates the process environment.
func Load() (Config, error) {
	var errs []error
	collect := func(err error) {
		if err != nil {
			errs = append(errs, err)
		}
	}
	inboundToken, err := secret("ORKA_GATEWAY_INBOUND_TOKEN")
	collect(err)
	outboundToken, err := secret("ORKA_GATEWAY_OUTBOUND_TOKEN")
	collect(err)
	requestTimeout, err := durationEnv("REQUEST_TIMEOUT", 15*time.Second)
	collect(err)
	sendTimeout, err := durationEnv("SEND_TIMEOUT", time.Minute)
	collect(err)
	shutdownTimeout, err := durationEnv("SHUTDOWN_TIMEOUT", 20*time.Second)
	collect(err)
	allowlist, err := imessage.ParseAllowlist(os.Getenv("IMESSAGE_ALLOWED_SENDERS"))
	if err != nil {
		errs = append(errs, fmt.Errorf("IMESSAGE_ALLOWED_SENDERS: %w", err))
	}
	var logLevel slog.Level
	if err := logLevel.UnmarshalText([]byte(envOr("LOG_LEVEL", "info"))); err != nil {
		errs = append(errs, errors.New("LOG_LEVEL must be debug, info, warn, or error"))
	}
	defaultDatabase := "adapter.db"
	if home, err := os.UserHomeDir(); err == nil {
		defaultDatabase = filepath.Join(home, "Library", "Application Support", "orka-gateway-imessage", "adapter.db")
	}
	cfg := Config{
		ListenAddress:       envOr("LISTEN_ADDRESS", "127.0.0.1:8787"),
		DatabasePath:        envOr("DATABASE_PATH", defaultDatabase),
		IMSGPath:            envOr("IMSG_PATH", "imsg"),
		IMSGDatabasePath:    strings.TrimSpace(os.Getenv("IMSG_DB_PATH")),
		AccountID:           strings.TrimSpace(os.Getenv("IMESSAGE_ACCOUNT_ID")),
		Allowlist:           allowlist,
		ConformanceChatGUID: strings.TrimSpace(os.Getenv("IMESSAGE_CONFORMANCE_CHAT_GUID")),
		OrkaIngressURL:      strings.TrimSpace(os.Getenv("ORKA_GATEWAY_INGRESS_URL")),
		OrkaInboundToken:    inboundToken,
		OrkaOutboundToken:   outboundToken,
		RequestTimeout:      requestTimeout,
		SendTimeout:         sendTimeout,
		ShutdownTimeout:     shutdownTimeout,
		LogLevel:            logLevel,
		AdapterVersion:      envOr("ADAPTER_VERSION", "dev"),
	}
	for name, value := range map[string]string{
		"IMESSAGE_ACCOUNT_ID":         cfg.AccountID,
		"ORKA_GATEWAY_INGRESS_URL":    cfg.OrkaIngressURL,
		"ORKA_GATEWAY_INBOUND_TOKEN":  cfg.OrkaInboundToken,
		"ORKA_GATEWAY_OUTBOUND_TOKEN": cfg.OrkaOutboundToken,
	} {
		if value == "" {
			errs = append(errs, fmt.Errorf("%s is required", name))
		}
	}
	if cfg.OrkaInboundToken != "" && cfg.OrkaInboundToken == cfg.OrkaOutboundToken {
		errs = append(errs, errors.New("orka inbound and outbound tokens must differ"))
	}
	if len(errs) > 0 {
		return Config{}, errors.Join(errs...)
	}
	return cfg, nil
}

// secret reads NAME or the file named by NAME_FILE, never both. Secret files
// must not be group-writable or world-accessible.
func secret(name string) (string, error) {
	value := strings.TrimSpace(os.Getenv(name))
	file := strings.TrimSpace(os.Getenv(name + "_FILE"))
	if value != "" && file != "" {
		return "", fmt.Errorf("set only one of %s or %s_FILE", name, name)
	}
	if file == "" {
		return value, nil
	}
	info, err := os.Stat(file)
	if err != nil {
		return "", fmt.Errorf("inspect %s_FILE: %w", name, err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("%s_FILE must be a regular file", name)
	}
	if info.Mode().Perm()&0o027 != 0 {
		return "", fmt.Errorf("%s_FILE must not be group-writable or world-accessible", name)
	}
	data, err := os.ReadFile(file) // #nosec G304 -- operator-configured secret path
	if err != nil {
		return "", fmt.Errorf("read %s_FILE: %w", name, err)
	}
	return strings.TrimSpace(string(data)), nil
}

func envOr(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func durationEnv(name string, fallback time.Duration) (time.Duration, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := time.ParseDuration(value)
	if err != nil || parsed <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration", name)
	}
	return parsed, nil
}
