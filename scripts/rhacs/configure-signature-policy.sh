#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
: "${ROX_ENDPOINT:?Set ROX_ENDPOINT}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN}"

integration_name="RHACS AI Demo Cosign Key"
policy_name="Demo - Unsigned OpenClaw release blocked"
vulnerable_policy_name="Demo - Critical OpenClaw release blocked"
affected_component_pattern='openclaw=2026\.2\.13([-._][a-zA-Z0-9]+)*$'
public_key="$repo_dir/.work/cosign/rhacs-demo.pub"
[ -s "$public_key" ] || { echo "Missing $public_key; run sign-release-v2.sh first" >&2; exit 1; }

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

cluster_id=$(central_api GET /v1/clusters | jq -r '.clusters[]? | select(.name=="production") | .id' | head -1)
[ -n "$cluster_id" ] || { echo "RHACS cluster 'production' not found" >&2; exit 1; }
policy_body=$(jq -nc --arg cid "$cluster_id" --arg iid "$integration_id" --arg name "$policy_name" '{
  name:$name,
  description:"The OpenClaw artifact is not verified with the approved Cosign release key, so its producer and release path cannot be established.",
  rationale:"Software provenance must be verified against the immutable image digest before an OpenClaw release can be promoted.",
  remediation:"Build the approved OpenClaw release, sign its immutable digest with the authorized release key, and verify the signature before promotion.",
  disabled:false,
  categories:["Supply Chain Security"],
  lifecycleStages:["BUILD","DEPLOY"],
  eventSource:"NOT_APPLICABLE",
  exclusions:[],
  scope:[{cluster:$cid,namespace:"ai-email-demo",label:{key:"app",value:"openclaw"}}],
  severity:"HIGH_SEVERITY",
  enforcementActions:["FAIL_BUILD_ENFORCEMENT","FAIL_DEPLOYMENT_CREATE_ENFORCEMENT"],
  notifiers:[],
  policyVersion:"1.1",
  policySections:[{sectionName:"OpenClaw images require the demo release key",policyGroups:[
    {fieldName:"Image Remote",booleanOperator:"OR",negate:false,values:[{value:"ai-email-demo/openclaw"}]},
    {fieldName:"Image Signature Verified By",booleanOperator:"OR",negate:false,values:[{value:$iid}]}
  ]}],
  mitreAttackVectors:[{tactic:"TA0001",techniques:["T1195.002"]}],
  criteriaLocked:false,
  mitreVectorsLocked:false,
  isDefault:false,
  source:"IMPERATIVE"
}')
policy_id=$(central_api GET /v1/policies | jq -r --arg name "$policy_name" \
  '.policies[]? | select(.name==$name) | .id' | head -1)
if [ -n "$policy_id" ]; then
  policy_body=$(jq -c --arg id "$policy_id" '. + {id:$id}' <<<"$policy_body")
  central_api PUT "/v1/policies/$policy_id" "$policy_body" >/dev/null
else
  policy_id=$(central_api POST /v1/policies "$policy_body" | jq -r '.id')
fi
[ -n "$policy_id" ] && [ "$policy_id" != null ] || { echo "RHACS signature policy failed" >&2; exit 1; }

echo "RHACS signature integration: $integration_id"
echo "RHACS signature policy: $policy_id"
echo "Scope: production / ai-email-demo / deployment label app=openclaw"
echo "Enforcement: build check and deployment-create admission"

# Match the historical npm component and the complete affected January release
# range directly. This keeps the organizational version baseline independent of
# a vulnerability identifier or vulnerability-database timing.
vulnerable_policy_body=$(jq -nc --arg cid "$cluster_id" --arg name "$vulnerable_policy_name" --arg pattern "$affected_component_pattern" '{
  name:$name,
  description:"This image contains OpenClaw 2026.2.13, a release affected by Critical security issues. The selected supply-chain redirection issue is fixed in 2026.3.22.",
  rationale:"Incomplete host environment sanitization could redirect package resolution or runtime bootstrap to attacker-controlled infrastructure. This policy demonstrates deterministic component-version control without reproducing the flaw.",
  remediation:"Rebuild the workload with OpenClaw 2026.3.22 or later, scan the new digest, sign it, and promote only the signed digest.",
  disabled:false,
  categories:["Vulnerability Management","Supply Chain Security"],
  lifecycleStages:["BUILD","DEPLOY"],
  eventSource:"NOT_APPLICABLE",
  exclusions:[],
  scope:[{cluster:$cid,namespace:"ai-email-demo",label:{key:"app",value:"openclaw"}}],
  severity:"CRITICAL_SEVERITY",
  enforcementActions:["FAIL_BUILD_ENFORCEMENT","FAIL_DEPLOYMENT_CREATE_ENFORCEMENT"],
  notifiers:[],
  policyVersion:"1.1",
  policySections:[{sectionName:"Affected OpenClaw runtime component",policyGroups:[
    {fieldName:"Image Component",booleanOperator:"OR",negate:false,values:[{value:$pattern}]}
  ]}],
  mitreAttackVectors:[{tactic:"TA0001",techniques:["T1195.001"]}],
  criteriaLocked:false,
  mitreVectorsLocked:false,
  isDefault:false,
  source:"IMPERATIVE"
}')
vulnerable_policy_id=$(central_api GET /v1/policies | jq -r --arg name "$vulnerable_policy_name" \
  '.policies[]? | select(.name==$name) | .id' | head -1)
if [ -n "$vulnerable_policy_id" ]; then
  vulnerable_policy_body=$(jq -c --arg id "$vulnerable_policy_id" '. + {id:$id}' <<<"$vulnerable_policy_body")
  central_api PUT "/v1/policies/$vulnerable_policy_id" "$vulnerable_policy_body" >/dev/null
else
  vulnerable_policy_id=$(central_api POST /v1/policies "$vulnerable_policy_body" | jq -r '.id')
fi
[ -n "$vulnerable_policy_id" ] && [ "$vulnerable_policy_id" != null ] || { echo "RHACS vulnerable-version policy failed" >&2; exit 1; }
echo "RHACS vulnerable-version policy: $vulnerable_policy_id"

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
