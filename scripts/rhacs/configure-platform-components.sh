#!/usr/bin/env bash
set -euo pipefail

: "${ROX_ENDPOINT:?Set ROX_ENDPOINT}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN}"

rule_name="AI demo supporting platform"
namespace_regex='^(demo-platform|demo-webhook|developer-devspaces|external-sender|hostpath-provisioner|openshift-devspaces|openshift-pipelines)$'

central_api() {
  local method=$1 path=$2 body=${3:-}
  local args=(-kfsS -X "$method" -H "Authorization: Bearer $ROX_API_TOKEN" -H 'Content-Type: application/json')
  [ -n "$body" ] && args+=(--data "$body")
  curl "${args[@]}" "https://$ROX_ENDPOINT$path"
}

current=$(central_api GET /v1/config)
public_config=$(central_api GET /v1/config/public)
updated=$(jq -c --argjson publicConfig "$public_config" --arg name "$rule_name" --arg regex "$namespace_regex" '
  # The combined GET omits publicConfig in current RHACS releases, but the
  # PUT contract requires it. Fetch and restore it explicitly so the server
  # does not reject an otherwise valid platform-component update.
  .publicConfig = $publicConfig |
  .platformComponentConfig.rules = (
    [.platformComponentConfig.rules[]? | select(.name != $name)] +
    [{name:$name, namespaceRule:{regex:$regex}}]
  ) |
  .platformComponentConfig.needsReevaluation = true
' <<<"$current")

payload=$(jq -nc --argjson config "$updated" '{config:$config}')
central_api PUT /v1/config "$payload" >/dev/null

verified=$(central_api GET /v1/config | jq -r --arg name "$rule_name" '
  .platformComponentConfig.rules[]? | select(.name == $name) | .namespaceRule.regex')
[ "$verified" = "$namespace_regex" ] || {
  echo "RHACS platform-component rule was not persisted" >&2
  exit 1
}

echo "RHACS custom platform components: $verified"
echo "User workload retained: ai-email-demo"
