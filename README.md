<!-- markdownlint-disable MD013 -->

# Orka iMessage Gateway

Orka iMessage Gateway is a macOS menu bar app that connects Apple Messages to Orka Agents. It implements Orka's [`orka.gateway.v1`](https://github.com/orka-agents/orka/blob/main/docs/development/gateway-protocol-v1.md) protocol outside Orka core and runs on a Mac that is signed in to Messages. Orka and its Agents keep running in Kubernetes; the Mac only bridges messages in and replies out.

```text
iPhone ──iMessage──▶ Messages.app ◀── Orka iMessage Gateway (menu bar) ──HTTPS──▶ Orka
                     (chat.db)                    ▲
                                                  └── HTTPS tunnel ◀── Orka deliveries
```

The app reads new messages from `~/Library/Messages/chat.db` and sends replies through Messages' AppleScript interface, using the `IMsgCore` library from [imsg](https://github.com/openclaw/imsg), the bridge [OpenClaw](https://docs.openclaw.ai/channels/imessage) uses. It adds Orka's protocol, durable state, and a fail-closed allowlist.

## Safety model

A Mac's Messages account is usually a personal account, so the gateway is deliberately narrow:

- **Allowlisted senders only.** The allowed-senders list is required. Messages from anyone else are never forwarded to Orka, so Orka never sees them and cannot send a denial reply.
- **Replies only where you spoke first.** A delivery is sent only to a direct chat that produced an admitted inbound message and whose handle is still allowlisted. The gateway also checks Messages' own record that the chat has exactly that one participant. Group chats are never forwarded or answered, because a group reply reaches every member.
- **No history replay.** The first start records the newest existing message and begins after it. Every later start resumes from the last processed row, so messages that arrive while the gateway is stopped are processed and none are skipped. Messages older than 24 hours, Orka's event expiry, are never forwarded.
- **No duplicate sends.** Deliveries are idempotent in SQLite. A reply counts as sent only when its outgoing row appears in Messages. A send whose outcome cannot be proven is recorded as unknown and is never retried, even after a restart.
- **No reply loops.** Outgoing messages, including the gateway's own replies, are never forwarded. An inbound message whose text matches a gateway reply to the same chat within two minutes is dropped as an echo.
- **Text only.** Attachments, reactions, polls, edits, and unsends are not forwarded. Threads are not advertised.
- **Nothing logged.** Logs and the activity list never contain message text.

## Requirements

- macOS 14 or later, signed in to Messages with iMessage working.
- An Orka installation with gateways enabled (the default) and an Agent runtime.
- A public HTTPS URL that forwards to the gateway, such as a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/). Orka delivers only to public HTTPS endpoints.
- Xcode 27 or later to build; it packages SwiftPM resources where an installed app finds them. An Apple Development certificate lets macOS keep the app's permissions across rebuilds; without one the app is signed ad hoc.

## Set up a Messages account

Use a dedicated account: you text it from your phone, and its replies come from that account.

1. Create an Apple Account with an email address you control. iMessage works with an email address alone; a phone number works only as the number of an iPhone.
2. Add a separate macOS user on the Mac (**System Settings → Users & Groups**) so your own Messages stay signed in to your account. Log in as that user, open Messages, sign in with the new account, and turn on iMessage for its email address.
3. Keep that user logged in (fast user switching is enough) and install and run the app as that user. The app reads that user's Messages, and macOS grants its permissions per user.
4. Allowlist your own handle, and text the new account's email address from your phone.

## Install

```bash
make app                                          # builds and signs .build/app/OrkaIMessageGateway.app
cp -R .build/app/OrkaIMessageGateway.app /Applications/
open /Applications/OrkaIMessageGateway.app
```

The app lives in the menu bar. Grant its two permissions before it handles messages; the menu and **Settings → Permissions** link to both:

1. **Full Disk Access**, to read Messages: **System Settings → Privacy & Security → Full Disk Access**, add **Orka iMessage Gateway**, then quit and reopen the app.
2. **Automation → Messages**, to send: choose **Allow Sending with Messages…** and click **Allow**. Do this before Orka replies: a send waits on the macOS prompt, and a send whose outcome cannot be proven is never retried, so a reply that runs into the prompt is lost.

## Configure Orka

Run these in one shell, replacing the example values:

```bash
export KUBE_CONTEXT=my-cluster
export NAMESPACE=orka-system                       # the controller's watched namespace
export IMESSAGE_ACCOUNT_ID=my-mac-messages         # any stable name for this Messages account
export IMESSAGE_SENDER_ID=+14155551212             # your handle
export IMESSAGE_CHAT_GUID='any;-;+14155551212'     # the chat with your handle; see below
export AGENT_MODEL=your-provider-supported-codex-model
kc() { kubectl --context "${KUBE_CONTEXT}" --namespace "${NAMESPACE}" "$@"; }
```

The chat GUID is `any;-;<your handle>` on recent macOS and `iMessage;-;<your handle>` on older releases. Once the gateway runs, **Settings → Activity** shows the chat each forwarded message came from.

In the app, open **Settings → General** and click **Generate New Tokens**. Copy each token with its copy button and store it in Orka:

```bash
pbpaste | kc create secret generic imessage-gateway-inbound --from-file=token=/dev/stdin \
  --dry-run=client --output=yaml | kc apply -f -    # after copying the inbound token
pbpaste | kc create secret generic imessage-gateway-outbound --from-file=token=/dev/stdin \
  --dry-run=client --output=yaml | kc apply -f -    # after copying the outbound token
for direction in inbound outbound; do
  kc label secret "imessage-gateway-${direction}" "gateway.orka.ai/${direction}-auth=true" \
    gateway.orka.ai/gateway-name=imessage --overwrite
  kc annotate secret "imessage-gateway-${direction}" gateway.orka.ai/gateway-name=imessage --overwrite
done
```

## Connect the gateway

Expose the gateway's loopback listener over HTTPS. For a quick test, a [Quick Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/) works; its hostname changes on every restart, so annotate the Secret below again after each one:

```bash
cloudflared tunnel --url http://127.0.0.1:8787
export ADAPTER_URL=https://replace-with-generated-host.trycloudflare.com
```

The gateway posts events to Orka's API. When the API is not public, forward it to loopback; plaintext HTTP is accepted only for loopback. The API Service is `orka-api` in a kustomize install and `orka` in a Helm install:

```bash
kc port-forward service/orka-api 8081:8080 &   # or service/orka for Helm
```

In **Settings → General**, set:

- **Account ID** to `IMESSAGE_ACCOUNT_ID`.
- **Event endpoint** to `http://127.0.0.1:8081/api/v1/gateways/<namespace>/imessage/events`, or Orka's public URL with the same path.
- **Allowed senders** to `IMESSAGE_SENDER_ID`.

Click **Save**. The menu shows **Running on 127.0.0.1:8787**. Then point Orka at the tunnel and bind the chat to an Agent:

```bash
kc apply -f deploy/cluster/gatewayclass.yaml   # cluster-scoped; reuse if already installed
kc annotate secret imessage-gateway-outbound \
  gateway.orka.ai/adapter-endpoint="${ADAPTER_URL}" --overwrite
./scripts/render-routing.sh | kc apply -f -
```

`render-routing.sh` creates `Agent/imessage-ai` (a Codex `orka.harness.v2` Agent), `Gateway/imessage`, and `GatewayBinding/imessage-ai`. The binding admits only `IMESSAGE_SENDER_ID` in `IMESSAGE_CHAT_GUID` and queues messages while a turn runs. It validates every value before rendering.

## Verify

Use fully qualified resource names: on clusters with the Kubernetes Gateway API installed, `gatewayclass` and `gateway` resolve to that API instead of Orka's.

```bash
kc get gatewayclasses.gateway.orka.ai imessage-chat
kc get gateways.gateway.orka.ai/imessage gatewaybindings.gateway.orka.ai/imessage-ai
```

Both should report ready once Orka reaches the gateway through the tunnel. Then text the Mac's account from the allowlisted handle. The menu shows when the last message went to Orka and when the last reply was sent, and the reply arrives in the same chat:

```bash
kc get gatewaybindings.gateway.orka.ai/imessage-ai \
  -o 'jsonpath={.status.lastInboundActivity}{" -> "}{.status.lastOutboundActivity}{"\n"}'
```

To see why a message was skipped, stream the app's debug log:

```bash
log stream --level debug --predicate 'subsystem == "ai.orka.gateway-imessage"'
```

## Details

The gateway listens on `127.0.0.1` at the configured port (default `8787`). It serves `GET /healthz` and `GET /readyz` without authentication, and the protocol routes `GET /v1/health`, `GET /v1/capabilities`, and `POST /v1/deliveries` with the outbound token. It advertises interim delivery, so Agents can post progress updates with `reply_in_conversation`.

Settings live in the app's preferences, the tokens in your login keychain, and the gateway's state in `~/Library/Application Support/ai.orka.gateway-imessage/gateway.db`. The state's ROWID cursor belongs to one Messages database. If `chat.db` is replaced or restored, quit the app and delete that directory before reopening it so the gateway records the newest message again. Delivery records are not pruned.

Turn on **Launch at Login** in the menu to start the app at login; with **Start the gateway automatically** on, the gateway starts with it. Keep the tunnel running too, for example as a `cloudflared` service with a named tunnel, and keep the Mac awake.

## Build and test

```bash
make check                                   # build, unit tests, script checks
make test-orka-compatibility ORKA_DIR=/path/to/orka
make run                                     # build, sign, and open the app
```

The compatibility test runs Orka's conformance CLI twice, before and after a restart, against `gateway-conformance-host`: the same gateway with a fake Messages backend that records sends to a file. Nothing is sent. `GATEWAY_SIGNING` selects how `scripts/build-app.sh` signs the app: `dev` (default), `adhoc`, `developer-id`, or `unsigned`.

## Cleanup

```bash
kc delete gatewaybindings.gateway.orka.ai/imessage-ai gateways.gateway.orka.ai/imessage \
  agents.core.orka.ai/imessage-ai --ignore-not-found
kc delete secret/imessage-gateway-inbound secret/imessage-gateway-outbound --ignore-not-found
```

This keeps the shared `GatewayClass/imessage-chat`. Stop `cloudflared` and the port-forward too. To remove the app and its local state, quit it, then:

```bash
rm -rf /Applications/OrkaIMessageGateway.app "${HOME}/Library/Application Support/ai.orka.gateway-imessage"
defaults delete ai.orka.gateway-imessage
security delete-generic-password -s ai.orka.gateway-imessage -a orka-inbound-token
security delete-generic-password -s ai.orka.gateway-imessage -a orka-outbound-token
tccutil reset All ai.orka.gateway-imessage
```
