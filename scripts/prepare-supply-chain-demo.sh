#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir="$repo_dir/.work/rhacs"
rhacs_env="$repo_dir/.rhacs.env"
resign=false

if [[ ${1:-} == --resign ]]; then
  resign=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--resign]" >&2
  exit 2
fi

[[ -s "$rhacs_env" ]] || { echo "Missing $rhacs_env; run scripts/setup-rhacs-demo.sh --skip-install first." >&2; exit 1; }
set -a
source "$rhacs_env"
set +a

for tag in v1 v2; do
  oc -n ai-email-demo get "istag/openclaw:$tag" >/dev/null || {
    echo "Missing prebuilt openclaw:$tag. Run scripts/setup.sh openshift before preparing the show." >&2
    exit 1
  }
done

if $resign; then
  "$repo_dir/scripts/sign-release-v2.sh"
fi

[[ -s "$repo_dir/.work/cosign/rhacs-demo.pub" ]] || {
  echo "Missing the v2 signing key. Run this script once with --resign before the presentation." >&2
  exit 1
}

"$repo_dir/scripts/rhacs/configure-signature-policy.sh"
"$repo_dir/scripts/rhacs-ci-gate.sh" | tee "$work_dir/preparation.log"

registry_host=image-registry.openshift-image-registry.svc:5000
roxctl image scan --image "$registry_host/ai-email-demo/openclaw:v1" --force -o json \
  >"$work_dir/v1-image-scan.json"
roxctl image scan --image "$registry_host/ai-email-demo/openclaw:v2" --force -o json \
  >"$work_dir/v2-image-scan.json"
v1_critical=$(jq -r '.result.summary.CRITICAL // 0' "$work_dir/v1-image-scan.json")
v2_critical=$(jq -r '.result.summary.CRITICAL // 0' "$work_dir/v2-image-scan.json")
v1_openclaw_critical=$(jq '[.result.vulnerabilities[] | select(.componentName=="openclaw" and .componentVersion=="2026.2.13" and .cveSeverity=="CRITICAL")] | length' "$work_dir/v1-image-scan.json")
[[ $v1_critical -gt 0 && $v1_openclaw_critical -gt 0 ]] || {
  echo "RHACS did not report a Critical OpenClaw finding for v1; refresh Scanner data before presenting." >&2
  exit 1
}

v1_digest=$(oc -n ai-email-demo get istag openclaw:v1 -o jsonpath='{.image.metadata.name}')
v2_digest=$(oc -n ai-email-demo get istag openclaw:v2 -o jsonpath='{.image.metadata.name}')
prepared_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

cat >"$work_dir/presenter-summary.md" <<EOF
# Supply-chain stage ready

Prepared: $prepared_at

| Candidate | Evidence | Targeted result |
|---|---|---|
| v1 — \`openclaw@2026.2.13\` | real component affected by Critical GHSA-j7p2-qcwm-94v4 | blocked: version and signature |
| v2 — \`openclaw@2026.7.1\` | maintained component; approved Cosign signature verified | accepted by both targeted gates |

Current RHACS scan snapshot: v1 has **$v1_critical Critical** findings, including **$v1_openclaw_critical** attributed directly to \`openclaw@2026.2.13\`; v2 has **$v2_critical Critical** findings. Counts can change when the digest or RHACS vulnerability database changes.

Both RHACS policies are enabled for BUILD and DEPLOY. Deploy scope is restricted to cluster \`production\`, namespace \`ai-email-demo\`, and Deployment label \`app=openclaw\`.

- v1 digest: \`$v1_digest\`
- v2 digest: \`$v2_digest\`
- v1 was scanned and checked but never started.
- Full cached evidence: \`.work/rhacs/\`
EOF

echo
echo "Presentation evidence is cached. During the show run only:"
echo "  make show"
