# AGENTS.md

This repository is a macOS menu bar app that implements Orka's `orka.gateway.v1` adapter protocol for Apple Messages. It runs on a signed-in Mac and reads and sends through the `IMsgCore` library from [imsg](https://github.com/openclaw/imsg).

## Layout

- `Sources/GatewayCore`: the protocol, safety rules, durable state (SQLite), delivery handling, inbound forwarding, and the HTTP server. It has no Messages dependency.
- `Sources/MessagesBridge`: the `MessagesBackend` that uses `IMsgCore`.
- `Sources/OrkaIMessageGateway`: the SwiftUI menu bar app.
- `Sources/ConformanceHost`: a headless host with a fake Messages backend for Orka's conformance tool.

## Constraints

- Never commit, print, or log Orka bearer tokens, message text, or Messages database contents. Tokens live in the keychain.
- The sender allowlist is mandatory and fail-closed. Never forward a message from a non-allowlisted sender, and send only to direct chats whose handle is allowlisted and that produced an admitted inbound message (the conformance chat is the only exception and must itself be an allowlisted direct chat). Group chats are unsupported because a reply reaches every member.
- Never retry a send whose outcome is unknown. Only outcomes Messages proves were not dispatched are retryable, and a send counts as delivered only when its outgoing row appears.
- Tests use fake backends, and `ConformanceHost` must never touch Messages. Do not run anything that sends real messages without an explicitly approved recipient.
- Keep iMessage-specific code outside Orka core.
- Run `make check` after changes, and `make test-orka-compatibility ORKA_DIR=<orka checkout>` after protocol or delivery changes.
- Sign commits with `git commit -s` and use Conventional Commit subjects.
