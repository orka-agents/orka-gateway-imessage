<!-- markdownlint-disable MD013 -->

# Orka iMessage gateway adapter

`orka-gateway-imessage` connects Apple Messages to Orka Agents. It implements Orka's [`orka.gateway.v1`](https://github.com/orka-agents/orka/blob/main/docs/development/gateway-protocol-v1.md) protocol outside Orka core and runs on a Mac that is signed in to Messages.

```text
iPhone ──iMessage──▶ Messages.app ◀── imsg rpc (stdio) ◀── orka-gateway-imessage ──HTTPS──▶ Orka
                     (chat.db)                                       ▲
                                                                     └── HTTPS tunnel ◀── Orka deliveries
```

The adapter starts [`imsg rpc`](https://github.com/steipete/imsg) as a child process, the same bridge [OpenClaw](https://docs.openclaw.ai/channels/imessage) uses. `imsg` watches `~/Library/Messages/chat.db` for new messages and sends replies through Messages' AppleScript interface. The adapter adds Orka's protocol, durable state, and a fail-closed allowlist.

## Safety model

A Mac's Messages account is usually a personal account, so the adapter is deliberately narrow:

- **Allowlisted senders only.** `IMESSAGE_ALLOWED_SENDERS` is required. Messages from anyone else are never forwarded to Orka, so Orka never sees them and cannot send a denial reply.
- **Replies only where you spoke first.** A delivery is sent only to a chat that produced an admitted inbound message, and a direct chat's handle must still be allowlisted. Group chats are off unless `IMESSAGE_ALLOW_GROUPS=true`.
- **No history replay.** The first start begins at the newest message. Later starts resume from the last processed row, so messages that arrive while the adapter is down are processed and none are skipped.
- **No duplicate sends.** Deliveries are idempotent in SQLite. A send whose outcome `imsg` cannot prove is recorded as unknown and is never retried, even after a restart.
- **No reply loops.** Your own outgoing rows are ignored, and an inbound copy of text the adapter just sent to the same chat is dropped. A self-chat echoes each sent message back as an inbound row.
- **Text only.** Attachments, reactions, polls, edits, and unsends are not forwarded. Threads are not advertised.

## Requirements

- macOS 14 or later, signed in to Messages with iMessage working.
- `imsg` 0.19.0 or later: `brew install steipete/tap/imsg`.
- Permissions for the process that runs the adapter (your terminal app, or the adapter binary under launchd):
  - **Full Disk Access** to read `chat.db`.
  - **Automation → Messages** to send. macOS asks on the first send.
- An Orka installation with gateways enabled (the default) and an Agent runtime.
- A public HTTPS URL that forwards to the adapter, such as a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/). Orka delivers only to public HTTPS endpoints.
- Go 1.26 or later to build.

A dedicated Apple ID on the Mac is the clearest setup: you message it from your phone, and its replies come from that account. Using your own Apple ID also works through your self-chat (messaging your own number or email); the echo guard keeps it from looping.

## Build and test

```bash
make check                                   # vet, race tests, script checks
make build                                   # bin/orka-gateway-imessage
make test-orka-compatibility ORKA_DIR=/path/to/orka
```

The compatibility test runs Orka's conformance CLI against the adapter twice, before and after a restart, with `scripts/fake-imsg` standing in for Messages. Nothing is sent.

## Find the chat and handles

With Full Disk Access granted to your terminal:

```bash
imsg chats --limit 10 --json | jq '{guid, participants, service}'
```

Pick the direct chat you will use. Its `guid` (for example `iMessage;-;+14155551212`) is the Orka `contextId`, and its handle is the sender. Handles are E.164 phone numbers (`+14155551212`) or lowercase email addresses.

## Configure Orka

Run these in one shell, replacing the example values:

```bash
set -euo pipefail
export KUBE_CONTEXT=my-cluster
export NAMESPACE=orka-system                       # the controller's watched namespace
export IMESSAGE_ACCOUNT_ID=my-mac-messages         # any stable name for this Messages account
export IMESSAGE_SENDER_ID=+14155551212             # your handle
export IMESSAGE_CHAT_GUID='iMessage;-;+14155551212'
export AGENT_MODEL=your-provider-supported-codex-model
k() { kubectl --context "${KUBE_CONTEXT}" --namespace "${NAMESPACE}" "$@"; }
```

Create the two bearer tokens in owner-only files outside the repository:

```bash
export SECRET_DIR="${HOME}/.config/orka-gateway-imessage"
umask 077
mkdir -p "${SECRET_DIR}"
for direction in inbound outbound; do
  file="${SECRET_DIR}/orka-gateway-${direction}-token"
  [[ -e "${file}" ]] || openssl rand -hex 32 >"${file}"
  k create secret generic "imessage-gateway-${direction}" --from-file=token="${file}" \
    --dry-run=client --output=yaml | k apply -f -
  k label secret "imessage-gateway-${direction}" "gateway.orka.ai/${direction}-auth=true" \
    gateway.orka.ai/gateway-name=imessage --overwrite
  k annotate secret "imessage-gateway-${direction}" gateway.orka.ai/gateway-name=imessage --overwrite
done
```

## Run the adapter

Expose the adapter's loopback listener over HTTPS. For a quick test, a [Quick Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/) works; its hostname changes on every restart:

```bash
cloudflared tunnel --url http://127.0.0.1:8787
export ADAPTER_URL=https://replace-with-generated-host.trycloudflare.com
```

The adapter posts events to Orka's API. When the API is not public, forward it to loopback; plaintext HTTP is accepted only for loopback:

```bash
k port-forward service/orka-api 8081:8080 &
```

Start the adapter in another shell with the same variables:

```bash
make build
IMESSAGE_ALLOWED_SENDERS="${IMESSAGE_SENDER_ID}" \
ORKA_GATEWAY_INGRESS_URL="http://127.0.0.1:8081/api/v1/gateways/${NAMESPACE}/imessage/events" \
ORKA_GATEWAY_INBOUND_TOKEN_FILE="${SECRET_DIR}/orka-gateway-inbound-token" \
ORKA_GATEWAY_OUTBOUND_TOKEN_FILE="${SECRET_DIR}/orka-gateway-outbound-token" \
  ./bin/orka-gateway-imessage
```

Then point Orka at the tunnel and bind the chat to an Agent:

```bash
k apply -f deploy/cluster/gatewayclass.yaml   # cluster-scoped; reuse if already installed
k annotate secret imessage-gateway-outbound \
  gateway.orka.ai/adapter-endpoint="${ADAPTER_URL}" --overwrite
./scripts/render-routing.sh | k apply -f -
```

`render-routing.sh` creates `Agent/imessage-ai` (a Codex `orka.harness.v2` Agent), `Gateway/imessage`, and `GatewayBinding/imessage-ai`. The binding admits only `IMESSAGE_SENDER_ID` in `IMESSAGE_CHAT_GUID` and queues messages while a turn runs. It validates every value before rendering.

## Verify

```bash
k get gatewayclass imessage-chat
k get gateway/imessage gatewaybinding/imessage-ai
```

Both should report ready once Orka reaches the adapter through the tunnel. Then send a message to the Mac from the allowlisted handle. The adapter logs `forwarded iMessage to Orka`, the Agent runs, and the reply arrives in the same chat:

```bash
k get gatewaybinding/imessage-ai \
  -o 'jsonpath={.status.lastInboundActivity}{" -> "}{.status.lastOutboundActivity}{"\n"}'
```

Run with `LOG_LEVEL=debug` to see why a message was skipped. Logs never contain message text.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `IMESSAGE_ACCOUNT_ID` | required | Orka `accountId` for this Messages account |
| `IMESSAGE_ALLOWED_SENDERS` | required | Comma-separated handles allowed to reach Orka and receive replies |
| `IMESSAGE_ALLOW_GROUPS` | `false` | Forward allowlisted senders' group-chat messages and allow group replies |
| `IMESSAGE_CONFORMANCE_CHAT_GUID` | empty | Allowlisted direct chat that receives Orka conformance probe sends |
| `ORKA_GATEWAY_INGRESS_URL` | required | `.../api/v1/gateways/<namespace>/imessage/events` |
| `ORKA_GATEWAY_INBOUND_TOKEN[_FILE]` | required | Token the adapter sends to Orka |
| `ORKA_GATEWAY_OUTBOUND_TOKEN[_FILE]` | required | Token Orka sends to the adapter; must differ from the inbound token |
| `LISTEN_ADDRESS` | `127.0.0.1:8787` | Adapter listener for the tunnel |
| `DATABASE_PATH` | `~/Library/Application Support/orka-gateway-imessage/adapter.db` | Durable cursor, reply chats, and deliveries |
| `IMSG_PATH` | `imsg` | `imsg` executable |
| `IMSG_DB_PATH` | empty | Alternate Messages database passed to `imsg rpc --db` |
| `SEND_TIMEOUT` | `60s` | Upper bound for one `imsg` send |
| `REQUEST_TIMEOUT` | `15s` | Orka ingress request timeout |
| `SHUTDOWN_TIMEOUT` | `20s` | Graceful shutdown deadline |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, or `error` |

The adapter serves `GET /healthz` and `GET /readyz` without authentication, and the protocol routes `GET /v1/health`, `GET /v1/capabilities`, and `POST /v1/deliveries` with the outbound token. It advertises interim delivery, so Agents can post progress updates with `reply_in_conversation`.

The ROWID cursor belongs to one Messages database. If `chat.db` is replaced or restored, stop the adapter and delete its database before restarting so it starts again at the newest message. Delivery records are not pruned.

## Run at login with launchd

1. Build and install the binary somewhere stable, for example `~/.local/bin/orka-gateway-imessage`.
2. Copy `deploy/launchd/ai.orka.gateway-imessage.plist` to `~/Library/LaunchAgents/` and replace every `REPLACE_WITH_*` value.
3. Grant **Full Disk Access** to the installed adapter binary. Under launchd it, not your terminal, is the process macOS checks for `imsg`.
4. Load it, and approve the Automation prompt on the first reply:

```bash
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/ai.orka.gateway-imessage.plist
launchctl kickstart -k "gui/$(id -u)/ai.orka.gateway-imessage"
```

Keep the tunnel running too, for example as a `cloudflared` service with a named tunnel, and keep the Mac awake.

## Cleanup

```bash
launchctl bootout "gui/$(id -u)/ai.orka.gateway-imessage" 2>/dev/null || true
k delete gatewaybinding/imessage-ai gateway/imessage agent/imessage-ai --ignore-not-found
k delete secret/imessage-gateway-inbound secret/imessage-gateway-outbound --ignore-not-found
```

This keeps the shared `GatewayClass/imessage-chat` and the adapter's local database.
