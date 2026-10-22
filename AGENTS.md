# AGENTS.md

This repository implements an out-of-tree Apple iMessage adapter for Orka's `orka.gateway.v1` protocol. It runs on a signed-in Mac and drives Messages through [`imsg rpc`](https://github.com/steipete/imsg).

## Constraints

- Never commit, print, or log Orka bearer tokens, message text, or Messages database contents.
- Secrets come from environment variables or owner-only `*_FILE` paths. The `imsg` child never receives `ORKA_*` variables.
- The sender allowlist is mandatory and fail-closed. Never forward a message from a non-allowlisted sender, and never send to a chat that did not produce an admitted inbound message from an allowlisted handle (the conformance chat is the only exception and must itself be an allowlisted direct chat).
- Never retry a send whose outcome is unknown. Only outcomes `imsg` proves were not dispatched are retryable.
- Automated tests use `scripts/fake-imsg`. Do not run tests or tools that send real messages without an explicitly approved recipient.
- Keep iMessage-specific code outside Orka core.
- Run `make check` after changes, and `make test-orka-compatibility ORKA_DIR=<orka checkout>` after protocol or delivery changes.
- Sign commits with `git commit -s` and use Conventional Commit subjects.
