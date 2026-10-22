package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/orka-agents/orka-gateway-imessage/internal/adapter"
	"github.com/orka-agents/orka-gateway-imessage/internal/config"
	"github.com/orka-agents/orka-gateway-imessage/internal/imsg"
	"github.com/orka-agents/orka-gateway-imessage/internal/store"
)

var version = "dev"

func main() {
	if err := run(); err != nil {
		slog.New(slog.NewJSONHandler(os.Stderr, nil)).Error("adapter stopped", "error", err.Error())
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel}))
	if cfg.AdapterVersion == "dev" {
		cfg.AdapterVersion = version
	}
	imsgPath, err := exec.LookPath(cfg.IMSGPath)
	if err != nil {
		return fmt.Errorf("find imsg (install with `brew install steipete/tap/imsg` or set IMSG_PATH): %w", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	database, err := store.Open(ctx, cfg.DatabasePath)
	if err != nil {
		return err
	}
	defer database.Close() //nolint:errcheck

	supervisor := imsg.NewSupervisor(imsg.Options{
		Path: imsgPath, DatabasePath: cfg.IMSGDatabasePath,
		Env: imsg.ChildEnvironment(os.Environ()), Logger: logger,
	})
	defer supervisor.Close()
	if _, err := supervisor.Status(ctx); err != nil {
		logger.Warn("imsg rpc is not ready yet; retrying in the background", "error", err.Error())
	}

	server, err := adapter.New(adapter.Config{
		AccountID: cfg.AccountID, Allowlist: cfg.Allowlist, ConformanceChatGUID: cfg.ConformanceChatGUID,
		IngressURL: cfg.OrkaIngressURL, IngressBearerToken: cfg.OrkaInboundToken,
		OutboundBearerToken: cfg.OrkaOutboundToken, AdapterVersion: cfg.AdapterVersion,
		SendTimeout: cfg.SendTimeout, HTTPClient: &http.Client{Timeout: cfg.RequestTimeout}, Logger: logger,
	}, database, adapter.FromSupervisor(supervisor))
	if err != nil {
		return err
	}

	httpServer := &http.Server{
		Addr: cfg.ListenAddress, Handler: server.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       cfg.RequestTimeout,
		WriteTimeout:      cfg.SendTimeout + 15*time.Second,
		IdleTimeout:       60 * time.Second,
	}
	serverErr := make(chan error, 1)
	go func() {
		logger.Info("starting iMessage gateway adapter", "address", cfg.ListenAddress, "version", cfg.AdapterVersion,
			"allowlisted_handles", cfg.Allowlist.Len())
		serverErr <- httpServer.ListenAndServe()
	}()
	var inbound sync.WaitGroup
	inbound.Add(1)
	go func() {
		defer inbound.Done()
		server.RunInbound(ctx)
	}()

	select {
	case <-ctx.Done():
		err = nil
	case err = <-serverErr:
		stop()
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	if shutdownErr := httpServer.Shutdown(shutdownCtx); shutdownErr != nil && err == nil {
		err = shutdownErr
	}
	inbound.Wait()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
