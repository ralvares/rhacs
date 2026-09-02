#!/usr/bin/env bash
set -euo pipefail

for command_name in curl jq; do
    command -v "$command_name" >/dev/null 2>&1 || { echo "$command_name is required" >&2; exit 1; }
done
: "${ROX_ENDPOINT:?Set ROX_ENDPOINT for RHACS Central}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN to an RHACS API token}"

api="https://${ROX_ENDPOINT}"
auth=(-H "Authorization: Bearer $ROX_API_TOKEN" -H 'Content-Type: application/json')
policy_name='Demo - Unexpected Runtime Artifact'
legacy_name='Demo - Sensitive File Transfer via curl'

cluster_id=$(curl -ksS "${auth[@]}" "$api/v1/clusters" | jq -r \
    '.clusters[]? | select(.name == "production") | .id' | head -1)
[ -n "$cluster_id" ] || { echo 'RHACS secured cluster not found: production' >&2; exit 1; }

policies=$(curl -ksS "${auth[@]}" "$api/v1/policies")
policy_id=$(jq -r --arg name "$policy_name" \
    '.policies[]? | select(.name == $name) | .id' <<<"$policies" | head -1)
legacy_id=$(jq -r --arg name "$legacy_name" \
    '.policies[]? | select(.name == $name) | .id' <<<"$policies" | head -1)

if [ -n "$policy_id" ]; then
    policy=$(curl -ksS "${auth[@]}" "$api/v1/policies/$policy_id")
elif [ -n "$legacy_id" ]; then
    policy_id=$legacy_id
    policy=$(curl -ksS "${auth[@]}" "$api/v1/policies/$policy_id")
else
    source_id=$(jq -r \
        '.policies[]? | select(.name == "Process Targeting Cluster Kubelet Endpoint") | .id' \
        <<<"$policies" | head -1)
    [ -n "$source_id" ] || { echo 'Could not find a runtime policy template' >&2; exit 1; }
    policy=$(curl -ksS "${auth[@]}" "$api/v1/policies/$source_id" | jq \
        --arg name "$policy_name" '.id = "" | .name = $name | .isDefault = false | .SORTName = ""')
fi

policy=$(jq --arg cluster "$cluster_id" '
    .name = "Demo - Unexpected Runtime Artifact"
    | .description = "Detects creation or writable opening of the demo runtime-context staging artifact. The rule uses only file path and file operation evidence."
    | .rationale = "The personal-agent workload should not create a staged copy of its runtime context while preparing an email summary."
    | .remediation = "Inspect the file activity, agent session, process tree, and network graph; contain the workload and repair tool authorization."
    | .disabled = false
    | .severity = "HIGH_SEVERITY"
    | .categories = ["File Activity Monitoring"]
    | .lifecycleStages = ["RUNTIME"]
    | .eventSource = "DEPLOYMENT_EVENT"
    | .enforcementActions = []
    | .scope = [{"cluster": $cluster, "namespace": "ai-email-demo"}]
    | .policySections = [{
        "sectionName": "unexpected staged runtime context",
        "policyGroups": [
          {"fieldName":"File Path","booleanOperator":"OR","negate":false,"values":[{"value":"/tmp/agent-runtime-context.snapshot"}]},
          {"fieldName":"File Operation","booleanOperator":"OR","negate":false,"values":[{"value":"OPEN"},{"value":"CREATE"}]}
        ]
      }]
' <<<"$policy")

if [ -n "$policy_id" ]; then
    response=$(curl -ksS -X PUT "${auth[@]}" -d "$policy" "$api/v1/policies/$policy_id")
else
    response=$(curl -ksS -X POST "${auth[@]}" -d "$policy" "$api/v1/policies")
    policy_id=$(jq -r '.id // empty' <<<"$response")
fi
response_json=${response:-'{}'}
error=$(jq -r '.error // .message // empty' <<<"$response_json")
[ -z "$error" ] || { echo "Could not configure $policy_name: $error" >&2; exit 1; }
[ -n "$policy_id" ] || { echo "Could not resolve the policy id for $policy_name" >&2; exit 1; }

echo "Configured detect-only RHACS file policy: $policy_name ($policy_id)"
echo "  File Path: /tmp/agent-runtime-context.snapshot"
echo "  File Operations: Open (Writable), Create"
