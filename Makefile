SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

APP ?= orka-gateway-imessage
GO ?= go
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || printf 'dev')
ORKA_DIR ?=

.PHONY: help fmt vet test test-scripts test-orka-compatibility check build clean render-routing

help: ## Show available targets.
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make <target> [VAR=value]\n\n"} /^[a-zA-Z0-9_.-]+:.*## / {printf "  %-26s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

fmt: ## Format Go sources.
	gofmt -w cmd internal

vet: ## Run go vet.
	$(GO) vet ./...

test: ## Run unit tests with the race detector.
	$(GO) test -race ./...

test-scripts: ## Check shell and Python script syntax.
	bash -n scripts/render-routing.sh
	python3 -m py_compile scripts/fake-imsg scripts/test-orka-compatibility.py
	plutil -lint deploy/launchd/ai.orka.gateway-imessage.plist

test-orka-compatibility: ## Run Orka's conformance CLI against the adapter; set ORKA_DIR to an Orka checkout.
	python3 ./scripts/test-orka-compatibility.py --orka-dir "$(ORKA_DIR)"

check: vet test test-scripts ## Run all local checks.

build: ## Build the adapter into bin/.
	mkdir -p bin
	CGO_ENABLED=0 $(GO) build -trimpath -ldflags "-X main.version=$(VERSION)" -o "bin/$(APP)" ./cmd/$(APP)

render-routing: ## Render the Orka Agent, Gateway, and GatewayBinding for one chat.
	@./scripts/render-routing.sh

clean: ## Remove build artifacts.
	rm -rf bin
