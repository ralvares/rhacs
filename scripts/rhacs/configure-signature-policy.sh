#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
: "${ROX_ENDPOINT:?Set ROX_ENDPOINT}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN}"

integration_name="RHACS AI Demo Cosign Key"
policy_name="Demo - Unsigned OpenClaw release blocked"
vulnerable_policy_name="Demo - Critical OpenClaw release blocked"
affected_component_pattern='openclaw=2026\.2\.13([-._][a-zA-Z0-9]+)*$'
enforcement_description="build failure, Sensor containment, and admission rejection on deployment create/update"
public_key="$repo_dir/.work/cosign/rhacs-demo.pub"
[ -s "$public_key" ] || { echo "Missing $public_key; run make sign first" >&2; exit 1; }

central_api() {
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -ksS -X "$method" -H "Authorization: Bearer $ROX_API_TOKEN" \
      -H 'Content-Type: application/json' --data "$body" "https://$ROX_ENDPOINT$path"
  else
    curl -ksS -X "$method" -H "Authorization: Bearer $ROX_API_TOKEN" \
      "https://$ROX_ENDPOINT$path"
  fi
}

key_pem=$(cat "$public_key")
integration_body=$(jq -nc --arg name "$integration_name" --arg key "$key_pem" \
  '{name:$name,cosign:{publicKeys:[{name:"rhacs-ai-demo",publicKeyPemEnc:$key}]},cosignCertificates:[],transparencyLog:{enabled:false,url:"",validateOffline:false,publicKeyPemEnc:""}}')
integration_id=$(central_api GET /v1/signatureintegrations | jq -r --arg name "$integration_name" \
  '.integrations[]? | select(.name==$name) | .id' | head -1)
if [ -n "$integration_id" ]; then
  integration_body=$(jq -c --arg id "$integration_id" '. + {id:$id}' <<<"$integration_body")
  central_api PUT "/v1/signatureintegrations/$integration_id" "$integration_body" >/dev/null
else
  integration_id=$(central_api POST /v1/signatureintegrations "$integration_body" | jq -r '.id')
fi
[ -n "$integration_id" ] && [ "$integration_id" != null ] || { echo "RHACS signature integration failed" >&2; exit 1; }

for managed_policy in "$policy_name" "$vulnerable_policy_name"; do
  managed_resource=$(oc -n stackrox get securitypolicy -o json 2>/dev/null | jq -r \
    --arg name "$managed_policy" '.items[]? | select(.spec.policyName == $name) | .metadata.name' | head -1)
  if [ -z "$managed_resource" ]; then
    legacy_id=$(central_api GET /v1/policies | jq -r --arg name "$managed_policy" \
      '.policies[]? | select(.name==$name) | .id' | head -1)
    [ -z "$legacy_id" ] || central_api DELETE "/v1/policies/$legacy_id" >/dev/null
  fi
done

oc apply -f "$repo_dir/deploy/rhacs/policies/openclaw-version.yaml" >/dev/null
sed -e "s/SIGNATURE_INTEGRATION_ID/${integration_id}/g" \
  "$repo_dir/deploy/rhacs/policies/openclaw-signature.yaml" | oc apply -f - >/dev/null

for _ in $(seq 1 60); do
  policies=$(central_api GET /v1/policies)
  policy_id=$(jq -r --arg name "$policy_name" '.policies[]? | select(.name==$name and .disabled==false) | .id' <<<"$policies" | head -1)
  vulnerable_policy_id=$(jq -r --arg name "$vulnerable_policy_name" '.policies[]? | select(.name==$name and .disabled==false) | .id' <<<"$policies" | head -1)
  [ -n "$policy_id" ] && [ -n "$vulnerable_policy_id" ] && break
  sleep 2
done
[ -n "${policy_id:-}" ] && [ -n "${vulnerable_policy_id:-}" ] || {
  echo "RHACS SecurityPolicy resources did not become active before timeout" >&2
  exit 1
}

echo "RHACS signature integration: $integration_id"
echo "RHACS signature policy: $policy_id (SecurityPolicy/demo-unsigned-openclaw-release-blocked)"
echo "RHACS vulnerable-version policy: $vulnerable_policy_id (SecurityPolicy/demo-critical-openclaw-release-blocked)"
echo "Scope: production / ai-email-demo / deployment label app=openclaw"
echo "Enforcement: $enforcement_description"

# Remove superseded names from earlier iterations so the RHACS policy list
# presents one unambiguous OpenClaw version gate and one signature gate.
for superseded_policy_name in \
  "Demo - AI agent image must be signed" \
  "Demo - OpenClaw image must be signed" \
  "Demo - OpenClaw before 2026.1.29 blocked" \
  "Demo - OpenClaw 2026.2.13 blocked"; do
  superseded_policy_id=$(central_api GET /v1/policies | jq -r --arg name "$superseded_policy_name" \
    '.policies[]? | select(.name==$name) | .id' | head -1)
  if [ -n "$superseded_policy_id" ]; then
    central_api DELETE "/v1/policies/$superseded_policy_id" >/dev/null
    echo "Removed superseded policy: $superseded_policy_name"
  fi
done

# Remove the earlier privileged-YAML demo policy. The simplified build/deploy
# story has exactly two gates: affected OpenClaw and unsigned OpenClaw images.
old_policy_name="Demo - Privileged workload blocked"
old_policy_id=$(central_api GET /v1/policies | jq -r --arg name "$old_policy_name" \
  '.policies[]? | select(.name==$name) | .id' | head -1)
if [ -n "$old_policy_id" ]; then
  central_api DELETE "/v1/policies/$old_policy_id" >/dev/null
  echo "Removed superseded policy: $old_policy_name"
fi
