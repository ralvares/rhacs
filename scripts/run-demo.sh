#!/usr/bin/env sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cli=${CLI:-oc}

command -v "$cli" >/dev/null 2>&1 || { echo "$cli is required" >&2; exit 1; }

mail_host=$($cli -n ai-email-demo get route mail-api -o jsonpath='{.spec.host}')
run_id=$(date +%s)

echo "1/4 Resetting the mailbox and sending two normal messages over SMTP..."
curl -kfsS -X POST "https://${mail_host}/seed"
echo

echo "2/4 Asking OpenClaw to read the mailbox over IMAP..."
$cli -n ai-email-demo exec deployment/openclaw -- \
  node openclaw.mjs agent --agent main --session-id "normal-${run_id}" \
  --message "Summarize today's email." --thinking low --json --timeout 300

echo "3/4 Sending the HTML message from the external-sender namespace..."
CLI="$cli" "$repo_dir/scripts/send-external-html-email.sh"

echo "4/4 Asking the same question in a fresh OpenClaw conversation..."
$cli -n ai-email-demo exec deployment/openclaw -- \
  node openclaw.mjs agent --agent main --session-id "injected-${run_id}" \
  --message "Summarize today's email." --thinking low --json --timeout 300

echo "Receiver evidence:"
$cli -n demo-webhook logs deployment/demo-webhook --tail=20
