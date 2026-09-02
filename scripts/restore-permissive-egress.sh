#!/usr/bin/env sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cli=${CLI:-}
if [ -z "$cli" ]; then
  if command -v oc >/dev/null 2>&1 && oc api-resources --api-group=route.openshift.io 2>/dev/null | grep -q routes; then
    cli=oc
  else
    cli=kubectl
  fi
fi

"$cli" -n ai-email-demo delete networkpolicy openclaw-egress-after --ignore-not-found
"$cli" apply -f "$repo_dir/deploy/network-policy/before-permissive.yaml"
"$cli" -n ai-email-demo get networkpolicy

