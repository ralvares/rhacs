#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
policy_file="$repo_dir/deploy/rhacs/policies/unexpected-runtime-artifact.yaml"

for command_name in oc curl jq; do
    command -v "$command_name" >/dev/null 2>&1 || { echo "$command_name is required" >&2; exit 1; }
done
: "${ROX_ENDPOINT:?Set ROX_ENDPOINT for RHACS Central}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN to an RHACS API token}"

api="https://${ROX_ENDPOINT}"
auth=(-H "Authorization: Bearer $ROX_API_TOKEN" -H 'Content-Type: application/json')
policy_name='Demo - Unexpected Runtime Artifact'
legacy_name='Demo - Sensitive File Transfer via curl'

policies=$(curl -ksS "${auth[@]}" "$api/v1/policies")
policy_id=$(jq -r --arg name "$policy_name" \
    '.policies[]? | select(.name == $name) | .id' <<<"$policies" | head -1)
legacy_id=$(jq -r --arg name "$legacy_name" \
    '.policies[]? | select(.name == $name) | .id' <<<"$policies" | head -1)

managed_resource=$(oc -n stackrox get securitypolicy demo-unexpected-runtime-artifact \
    -o name 2>/dev/null || true)
if [ -z "$managed_resource" ]; then
    for unmanaged_id in "$policy_id" "$legacy_id"; do
        [ -z "$unmanaged_id" ] || curl -ksS -X DELETE "${auth[@]}" \
            "$api/v1/policies/$unmanaged_id" >/dev/null
    done
fi

oc apply -f "$policy_file" >/dev/null
for _ in $(seq 1 60); do
    accepted=$(oc -n stackrox get securitypolicy demo-unexpected-runtime-artifact \
        -o jsonpath='{.status.conditions[?(@.type=="AcceptedByCentral")].status}' 2>/dev/null || true)
    policy_id=$(oc -n stackrox get securitypolicy demo-unexpected-runtime-artifact \
        -o jsonpath='{.status.policyId}' 2>/dev/null || true)
    [ "$accepted" = True ] && [ -n "$policy_id" ] && break
    sleep 2
done
[ "$accepted" = True ] && [ -n "$policy_id" ] || {
    oc -n stackrox get securitypolicy demo-unexpected-runtime-artifact -o yaml >&2 || true
    echo "RHACS did not accept the declarative file-activity policy" >&2
    exit 1
}

echo "Configured detect-only RHACS file policy: $policy_name ($policy_id)"
echo "  Source: deploy/rhacs/policies/unexpected-runtime-artifact.yaml"
echo "  File Path: /tmp/agent-runtime-context.snapshot"
echo "  File Operations: Open (Writable), Create"
