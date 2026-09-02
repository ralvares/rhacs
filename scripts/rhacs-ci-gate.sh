#!/usr/bin/env sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir="$repo_dir/.work/rhacs"

command -v oc >/dev/null 2>&1 || { echo "oc is required" >&2; exit 1; }
command -v roxctl >/dev/null 2>&1 || { echo "roxctl is required" >&2; exit 1; }
: "${ROX_ENDPOINT:?Set ROX_ENDPOINT for RHACS Central}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN to a RHACS CI token}"

# CRC Routes use a locally signed certificate. Keep the exception constrained
# to the well-known OpenShift Local domain; other clusters must provide a CA or
# pass their own explicit roxctl TLS configuration.
case "$ROX_ENDPOINT" in
  *.apps-crc.testing|*.apps-crc.testing:*)
    export ROX_INSECURE_CLIENT_SKIP_TLS_VERIFY=true
    ;;
esac

registry_host=image-registry.openshift-image-registry.svc:5000
v1="$registry_host/ai-email-demo/openclaw:v1"
v2="$registry_host/ai-email-demo/openclaw:v2"

mkdir -p "$work_dir"
sed "s#REGISTRY_ROUTE#$registry_host#g" "$repo_dir/deploy/rhacs/bad-openclaw.yaml" > "$work_dir/v1-bad.yaml"
sed "s#REGISTRY_ROUTE#$registry_host#g" "$repo_dir/deploy/rhacs/clean-openclaw.yaml" > "$work_dir/v2-clean.yaml"

vulnerability_policy="Demo - Critical OpenClaw release blocked"
signature_policy="Demo - Unsigned OpenClaw release blocked"

has_policy() {
  jq -e --arg name "$2" '.. | objects | select(.name? == $name)' "$1" >/dev/null
}

central_policy() {
  policy_id=$(curl -ksS -H "Authorization: Bearer $ROX_API_TOKEN" \
    "https://$ROX_ENDPOINT/v1/policies" | jq -r --arg name "$1" \
    '.policies[]? | select(.name==$name) | .id' | head -1)
  [ -n "$policy_id" ] || return 1
  curl -ksS -H "Authorization: Bearer $ROX_API_TOKEN" \
    "https://$ROX_ENDPOINT/v1/policies/$policy_id"
}

echo "[1/6] Prove the blocked npm component version is present in the v1 SBOM"
v1_sbom="$repo_dir/sboms/openclaw-v1.cdx.json"
if ! jq -e '.components[] | select(.name == "openclaw" and .version == "2026.2.13")' "$v1_sbom" >/dev/null; then
  echo "ERROR: the v1 Syft SBOM does not contain openclaw 2026.2.13." >&2
  exit 1
fi
echo "The immutable v1 SBOM contains openclaw 2026.2.13. The image was not started."

echo "[2/6] Check v1 as a build artifact"
v1_image_check="$work_dir/v1-image-check.json"
roxctl image check --image "$v1" --force -o json >"$v1_image_check" 2>/dev/null || true
if ! has_policy "$v1_image_check" "$vulnerability_policy"; then
  echo "ERROR: v1 did not trigger the affected-OpenClaw build policy." >&2
  exit 1
fi
if ! has_policy "$v1_image_check" "$signature_policy"; then
  echo "ERROR: v1 did not trigger the unsigned-image build policy." >&2
  exit 1
fi
echo "v1 is rejected for the affected component and for missing the approved signature."

echo "[3/6] Check the app=openclaw v1 Kubernetes manifest"
bad_check="$work_dir/v1-deployment-check.json"
roxctl deployment check --cluster production --file "$work_dir/v1-bad.yaml" -o json >"$bad_check" 2>/dev/null || true
v1_manifest="$work_dir/v1-manifest.json"
oc create --dry-run=client -f "$work_dir/v1-bad.yaml" -o json >"$v1_manifest"
if ! jq -e '.metadata.labels.app == "openclaw" and (.spec.template.spec.containers | any(.image | endswith("/ai-email-demo/openclaw:v1")))' "$v1_manifest" >/dev/null; then
  echo "ERROR: v1 YAML is not labeled app=openclaw or does not select openclaw:v1." >&2
  exit 1
fi
for policy in "$vulnerability_policy" "$signature_policy"; do
  policy_json="$work_dir/$(printf '%s' "$policy" | tr ' /' '__').json"
  central_policy "$policy" >"$policy_json"
  if ! jq -e '.disabled == false and (.lifecycleStages | index("DEPLOY")) and (.enforcementActions | index("FAIL_DEPLOYMENT_CREATE_ENFORCEMENT")) and any(.scope[]?; .namespace == "ai-email-demo" and .label.key == "app" and .label.value == "openclaw")' "$policy_json" >/dev/null; then
    echo "ERROR: $policy is not enabled and label-scoped for deploy enforcement." >&2
    exit 1
  fi
done
echo "v1 YAML selects the vulnerable image and label scope; both RHACS deploy gates are enabled."
echo "The static deployment report is saved separately because roxctl does not evaluate resource scopes."

echo "[4/6] Prove the maintained npm component is present in the v2 SBOM"
v2_sbom="$repo_dir/sboms/openclaw-v2.cdx.json"
if ! jq -e '.components[] | select(.name == "openclaw" and .version == "2026.7.1")' "$v2_sbom" >/dev/null; then
  echo "ERROR: the v2 Syft SBOM does not contain openclaw 2026.7.1." >&2
  exit 1
fi
echo "The immutable v2 SBOM contains openclaw 2026.7.1. RHACS policy determines whether it meets the version baseline."

echo "[5/6] Check v2 as a signed build artifact"
v2_check="$work_dir/v2-image-check.json"
roxctl image check --image "$v2" --force -o json >"$v2_check" 2>/dev/null || true
if has_policy "$v2_check" "$vulnerability_policy"; then
  echo "ERROR: the affected-OpenClaw policy rejected v2." >&2
  exit 1
fi
if has_policy "$v2_check" "$signature_policy"; then
  echo "ERROR: RHACS did not verify the v2 registry signature." >&2
  exit 1
fi
echo "v2 passes both targeted build gates: fixed component and approved signature."

echo "[6/6] Check the app=openclaw v2 Kubernetes manifest"
v2_deploy_check="$work_dir/v2-deployment-check.json"
roxctl deployment check --cluster production --file "$work_dir/v2-clean.yaml" -o json >"$v2_deploy_check" 2>/dev/null || true
v2_manifest="$work_dir/v2-manifest.json"
oc create --dry-run=client -f "$work_dir/v2-clean.yaml" -o json >"$v2_manifest"
if ! jq -e 'select(.kind == "Deployment") | .metadata.labels.app == "openclaw" and ([.spec.template.spec.initContainers[]?.image,.spec.template.spec.containers[]?.image] | all(endswith("/ai-email-demo/openclaw:v2")))' "$v2_manifest" >/dev/null; then
  echo "ERROR: v2 YAML is not labeled app=openclaw or does not use openclaw:v2 throughout." >&2
  exit 1
fi
echo "v2 YAML selects the fixed, signed image under the same app=openclaw scope."

echo "RHACS proof complete: v1 blocked twice; v2 fixed and signed; both image and YAML checks verified."
echo "Any unrelated findings remain in the JSON reports: signed does not mean vulnerability-free."
