#!/usr/bin/env bash
set -euo pipefail

cli=${CLI:-}
if [ -z "$cli" ]; then
  if command -v oc >/dev/null 2>&1 && oc api-resources --api-group=route.openshift.io 2>/dev/null | grep -q routes; then
    cli=oc
  else
    cli=kubectl
  fi
fi

password=$($cli -n ai-email-demo get secret mail-credentials -o go-template='{{index .data "mail-password" | base64decode}}')
mail_user=$($cli -n ai-email-demo get secret mail-credentials -o go-template='{{index .data "mail-user" | base64decode}}')
mail_address=$($cli -n ai-email-demo get secret mail-credentials -o go-template='{{index .data "mail-address" | base64decode}}')
gateway_token=$($cli -n ai-email-demo get secret openclaw-credentials -o go-template='{{index .data "gateway-token" | base64decode}}')
openclaw_route=$($cli -n ai-email-demo get route openclaw -o jsonpath='{.spec.host}' 2>/dev/null || true)
version_output=$($cli -n ai-email-demo exec deployment/openclaw -c openclaw -- \
  node /opt/openclaw/openclaw.mjs --version 2>/dev/null || true)
openclaw_version=$(printf '%s\n' "$version_output" | grep -Eo '[0-9]{4}\.[0-9]+\.[0-9]+' | head -1 || true)
[ -n "$openclaw_version" ] || openclaw_version=unknown

printf 'DEMO CREDENTIALS\n'
printf 'OpenClaw version:       %s\n' "$openclaw_version"
printf 'OpenClaw URL:           https://%s\n' "$openclaw_route"
printf 'OpenClaw gateway token: %s\n' "$gateway_token"
printf 'Webmail user:           %s\n' "$mail_user"
printf 'Webmail password:       %s\n' "$password"
printf 'Mailbox address:        %s\n' "$mail_address"

case "$openclaw_version" in
  2026.2.*|2026.1.*)
    printf '\nOpenClaw %s uses the v1 demo connection flow; no device approval is required.\n' "$openclaw_version"
    ;;
  unknown)
    printf '\nOpenClaw is not ready, so its device approval mode could not be detected.\n' >&2
    exit 1
    ;;
  *)
    printf '\nChecking for pending browser devices supported by OpenClaw %s...\n' "$openclaw_version"
    devices_json=$($cli -n ai-email-demo exec deployment/openclaw -c openclaw -- \
      node /opt/openclaw/openclaw.mjs devices list --json \
      --url ws://127.0.0.1:8080 --token "$gateway_token" 2>/dev/null || true)
    request_ids=$(printf '%s\n' "$devices_json" | jq -r \
      '.. | objects | .requestId? // empty' 2>/dev/null | sort -u || true)
    if [ -z "$request_ids" ]; then
      printf 'No pending browser device requests. Open the URL, click Connect, then run make credentials again if pairing is requested.\n'
    else
      approved=0
      while IFS= read -r request_id; do
        [ -n "$request_id" ] || continue
        $cli -n ai-email-demo exec deployment/openclaw -c openclaw -- \
          node /opt/openclaw/openclaw.mjs devices approve "$request_id" --json \
          --url ws://127.0.0.1:8080 --token "$gateway_token" >/dev/null
        printf 'Approved browser device request: %s\n' "$request_id"
        approved=$((approved + 1))
      done <<<"$request_ids"
      printf 'Approved %d pending browser device(s). Click Connect again.\n' "$approved"
    fi
    ;;
esac
