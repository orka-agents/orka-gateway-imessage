#!/usr/bin/env bash
# Render the Orka routing objects for one iMessage chat to stdout.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require() {
  local name="$1" pattern="$2" value="${!1:-}"
  if [[ ! "${value}" =~ ${pattern} ]]; then
    printf '%s is missing or invalid\n' "${name}" >&2
    exit 2
  fi
}

require NAMESPACE '^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'
require ADAPTER_URL '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$'
require AGENT_MODEL '^[A-Za-z0-9._:/-]{1,128}$'
require IMESSAGE_ACCOUNT_ID '^[A-Za-z0-9._@+-]{1,128}$'
require IMESSAGE_CHAT_GUID '^[A-Za-z0-9._-]+;-;(\+[0-9]{7,15}|[a-z0-9._%+-]+@[a-z0-9.-]+)$'
require IMESSAGE_SENDER_ID '^(\+[0-9]{7,15}|[a-z0-9._%+-]+@[a-z0-9.-]+)$'

for file in agent.yaml gateway.yaml gatewaybinding.yaml; do
  printf -- '---\n'
  sed -e "s|REPLACE_WITH_NAMESPACE|${NAMESPACE}|g" \
    -e "s|REPLACE_WITH_ADAPTER_URL|${ADAPTER_URL}|g" \
    -e "s|REPLACE_WITH_AGENT_MODEL|${AGENT_MODEL}|g" \
    -e "s|REPLACE_WITH_IMESSAGE_ACCOUNT_ID|${IMESSAGE_ACCOUNT_ID}|g" \
    -e "s|REPLACE_WITH_IMESSAGE_CHAT_GUID|${IMESSAGE_CHAT_GUID}|g" \
    -e "s|REPLACE_WITH_IMESSAGE_SENDER_ID|${IMESSAGE_SENDER_ID}|g" \
    "${root}/deploy/routing/${file}"
done
