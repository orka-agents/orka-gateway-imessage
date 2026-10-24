SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

ORKA_DIR ?=

.PHONY: help build test test-scripts test-orka-compatibility check app run render-routing clean

help: ## Show available targets.
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make <target> [VAR=value]\n\n"} /^[a-zA-Z0-9_.-]+:.*## / {printf "  %-26s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build every target in debug.
	swift build

test: ## Run the unit tests.
	swift test

test-scripts: ## Check shell and Python script syntax.
	bash -n scripts/build-app.sh scripts/render-routing.sh
	python3 -m py_compile scripts/test-orka-compatibility.py
	plutil -lint Resources/OrkaIMessageGateway.entitlements

test-orka-compatibility: ## Run Orka's conformance CLI against the gateway; set ORKA_DIR to an Orka checkout.
	python3 ./scripts/test-orka-compatibility.py --orka-dir "$(ORKA_DIR)"

check: build test test-scripts ## Run all local checks.

app: ## Build and sign .build/app/OrkaIMessageGateway.app.
	./scripts/build-app.sh release

run: app ## Build the app and open it.
	open .build/app/OrkaIMessageGateway.app

render-routing: ## Render the Orka Agent, Gateway, and GatewayBinding for one chat.
	@./scripts/render-routing.sh

clean: ## Remove build artifacts.
	rm -rf .build
