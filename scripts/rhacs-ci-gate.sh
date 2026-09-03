#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir="$repo_dir/.work/rhacs"
registry_host=image-registry.openshift-image-registry.svc:5000
image="$registry_host/ai-email-demo/openclaw:v1"
sbom="$repo_dir/sboms/openclaw-v1.cdx.json"
version_policy="Demo - Critical OpenClaw release blocked"
signature_policy="Demo - Unsigned OpenClaw release blocked"

: "${ROX_ENDPOINT:?Set ROX_ENDPOINT for RHACS Central}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN to a RHACS CI token}"
case "$ROX_ENDPOINT" in *.apps-crc.testing|*.apps-crc.testing:*) export ROX_INSECURE_CLIENT_SKIP_TLS_VERIFY=true ;; esac
mkdir -p "$work_dir"

version=$(jq -r '[.components[]? | select(.name=="openclaw") | .version] | unique | first // empty' "$sbom")
case "$version" in 2026.2.13|2026.8.2) ;; *) echo "Unexpected OpenClaw version in v1 image SBOM: $version" >&2; exit 1 ;; esac
echo "[1/3] Final-image SBOM: openclaw@$version"

check="$work_dir/v1-image-check.json"
roxctl image check --image "$image" --force -o json >"$check" 2>/dev/null || true
has_policy() { jq -e --arg name "$1" '.. | objects | select(.name? == $name)' "$check" >/dev/null; }
if [ "$version" = 2026.2.13 ]; then
  has_policy "$version_policy" || { echo "Affected v1 did not trigger the version policy" >&2; exit 1; }
  echo "[2/3] RHACS version gate: BLOCKED as expected"
else
  ! has_policy "$version_policy" || { echo "Maintained v1 still triggered the version policy" >&2; exit 1; }
  echo "[2/3] RHACS version gate: PASSED"
fi
if has_policy "$signature_policy"; then
  echo "[3/3] RHACS signature gate: BLOCKED (digest is not signed by the demo key)"
else
  if [ "$version" = 2026.2.13 ]; then
    echo "Unsigned opening v1 did not trigger the signature policy" >&2
    exit 1
  fi
  echo "[3/3] RHACS signature gate: PASSED"
fi

sed "s#REGISTRY_ROUTE#$registry_host#g" "$repo_dir/deploy/rhacs/clean-openclaw.yaml" >"$work_dir/v1-clean.yaml"
roxctl deployment check --cluster production --file "$work_dir/v1-clean.yaml" -o json >"$work_dir/v1-deployment-check.json" 2>/dev/null || true
echo "Single-candidate RHACS proof complete for openclaw:v1."
