#!/usr/bin/env sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cli=${CLI:-oc}
command -v "$cli" >/dev/null 2>&1 || { echo "$cli is required" >&2; exit 1; }

"$cli" apply -f "$repo_dir/deploy/external-demo/00-namespaces.yaml"
"$cli" -n external-sender delete job external-callback-sender --ignore-not-found
mail_address=$("$cli" -n ai-email-demo get secret mail-credentials -o go-template='{{index .data "mail-address" | base64decode}}')
sed "s/MAILBOX_ADDRESS/$mail_address/g" "$repo_dir/deploy/external-demo/30-callback-sender.yaml" | "$cli" apply -f -
"$cli" -n external-sender wait --for=condition=complete job/external-callback-sender --timeout=90s
"$cli" -n external-sender logs job/external-callback-sender
