#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rhacs_env="$repo_dir/.rhacs.env"
[ -f "$rhacs_env" ] || "$repo_dir/scripts/rhacs-login.sh" >/dev/null
set -a
# shellcheck disable=SC1090
source "$rhacs_env"
set +a

central_host=$(oc -n stackrox get route central -o jsonpath='{.spec.host}')
resolved=0
for namespace in ai-email-demo demo-webhook external-sender; do
  alerts=$(curl -kfsS --connect-timeout 5 --max-time 60 \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    "https://${central_host}/v1/alerts?query=Namespace%3A${namespace}")
  while IFS= read -r alert_id; do
    [ -n "$alert_id" ] || continue
    curl -kfsS --connect-timeout 5 --max-time 60 -X PATCH \
      -H "Authorization: Bearer $ROX_API_TOKEN" \
      -H 'Content-Type: application/json' -d '{}' \
      "https://${central_host}/v1/alerts/${alert_id}/resolve" >/dev/null
    resolved=$((resolved + 1))
  done < <(jq -r '.alerts[]? | select(.state == "ACTIVE" and .lifecycleStage == "RUNTIME") | .id' <<<"$alerts")
done
echo "Resolved $resolved active demo runtime alert(s)."
