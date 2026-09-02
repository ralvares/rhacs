#!/usr/bin/env sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cli=${CLI:-oc}
if [ -f "$repo_dir/.env" ]; then
  set -a
  . "$repo_dir/.env"
  set +a
fi
mail_user=${DEMO_MAIL_USER:-demo}
mail_password=${DEMO_MAIL_PASSWORD:-demo}
mail_domain=${DEMO_MAIL_DOMAIN:-demo.test}
mail_address="${mail_user}@${mail_domain}"
greenmail_opts="-Dgreenmail.setup.test.smtp -Dgreenmail.setup.test.imap -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.users=${mail_user}:${mail_password}@${mail_domain} -Dgreenmail.users.login=username"

command -v "$cli" >/dev/null 2>&1 || { echo "$cli is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

echo "[1/8] Checking the deployed demo..."
"$cli" -n ai-email-demo get deployment openclaw mail-server mail-api webmail >/dev/null
"$cli" -n demo-webhook get deployment demo-webhook >/dev/null

echo "[2/8] Applying the presentation mailbox credential..."
"$cli" -n ai-email-demo create secret generic mail-credentials \
  --from-literal=mail-user="$mail_user" \
  --from-literal=mail-password="$mail_password" \
  --from-literal=mail-address="$mail_address" \
  --from-literal=greenmail-opts="$greenmail_opts" \
  --dry-run=client -o yaml | "$cli" apply -f - >/dev/null
"$cli" -n ai-email-demo rollout restart deployment/mail-server deployment/mail-api >/dev/null
"$cli" -n ai-email-demo rollout status deployment/mail-server --timeout=120s >/dev/null
"$cli" -n ai-email-demo rollout status deployment/mail-api --timeout=120s >/dev/null

echo "[3/8] Restoring the permissive opening network state..."
CLI="$cli" "$repo_dir/scripts/restore-permissive-egress.sh" >/dev/null

echo "[4/8] Removing any sender Job from an earlier run..."
"$cli" -n external-sender delete job external-html-sender --ignore-not-found >/dev/null

echo "[5/8] Resetting the agent's conversation sessions..."
"$cli" -n ai-email-demo exec -c openclaw deployment/openclaw -- \
  env OPENCLAW_CONFIG_PATH=/home/node/.openclaw/reset-config.json \
  node openclaw.mjs reset --scope config+creds+sessions --yes --non-interactive \
  >/dev/null
# The generated provider cache survives OpenClaw's reset command. Remove only
# that derived file so a changed SecretRef/provider configuration is rebuilt.
"$cli" -n ai-email-demo exec -c openclaw deployment/openclaw -- \
  rm -f /home/node/.openclaw/agents/main/agent/models.json
"$cli" -n ai-email-demo rollout restart deployment/openclaw >/dev/null

echo "[6/8] Seeding only the two normal emails..."
mail_host=$("$cli" -n ai-email-demo get route mail-api -o jsonpath='{.spec.host}')
curl -kfsS -X POST "https://${mail_host}/seed" >/dev/null

echo "[7/8] Clearing previous receiver evidence..."
"$cli" -n demo-webhook exec deployment/demo-webhook -- python -c \
  "import urllib.request; print(urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8080/requests', method='DELETE')).read().decode())" \
  >/dev/null

echo "[8/8] Verifying the presentation baseline..."
"$cli" -n ai-email-demo wait --for=condition=Available \
  deployment/openclaw deployment/mail-server deployment/mail-api deployment/webmail \
  --timeout=60s >/dev/null
"$cli" -n demo-webhook wait --for=condition=Available deployment/demo-webhook \
  --timeout=60s >/dev/null
sessions_json=$("$cli" -n ai-email-demo exec -c openclaw deployment/openclaw -- \
  node openclaw.mjs sessions list --all-agents --limit all --json)
session_count=$(printf '%s' "$sessions_json" | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["totalCount"])')
[ "$session_count" -eq 0 ] || {
  echo "session reset failed: $session_count conversation(s) remain" >&2
  exit 1
}

echo
echo "Base demo is ready."
echo "  - two normal emails are in $mail_address"
echo "  - receiver history is empty"
echo "  - permissive before-policy is active"
echo "  - no injected email was sent"
echo "  - no chatbot request was executed"
echo "  - prior agent conversations were removed"
echo
"$cli" -n ai-email-demo get routes
echo
CLI="$cli" "$repo_dir/scripts/show-demo-credentials.sh"
echo
echo "Present manually:"
echo "  1. Open Roundcube and show the two normal emails."
echo "  2. Paste the gateway token and connect the chatbot; no pairing approval is required."
echo "  3. Ask the chatbot to summarize today's email."
echo "  4. When ready, run: ./scripts/send-external-html-email.sh"
echo "  5. Show the new HTML email, then ask the chatbot again."
echo "  6. For containment, run: ./scripts/restrict-egress.sh"
