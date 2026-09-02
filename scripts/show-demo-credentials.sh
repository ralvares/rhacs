#!/usr/bin/env sh
set -eu

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
printf 'Webmail user: %s\nWebmail password: %s\nMailbox address: %s\nOpenClaw gateway token: %s\n' "$mail_user" "$password" "$mail_address" "$gateway_token"
printf '\nOpen the OpenClaw route, paste the gateway token, and click Connect.\n'
printf 'Browser device pairing is disabled for this isolated presentation environment.\n'
