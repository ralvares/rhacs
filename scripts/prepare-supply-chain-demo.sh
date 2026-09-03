#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir="$repo_dir/.work/rhacs"
resign=false
[ "${1:-}" != --resign ] || resign=true
mkdir -p "$work_dir"

set -a
source "$repo_dir/.rhacs.env"
set +a
oc -n ai-email-demo get istag/openclaw:v1 >/dev/null
"$repo_dir/scripts/generate-sboms.sh"
$resign && "$repo_dir/scripts/sign-release-v2.sh"
"$repo_dir/scripts/rhacs/configure-signature-policy.sh"
"$repo_dir/scripts/rhacs-ci-gate.sh" | tee "$work_dir/preparation.log"

version=$(jq -r '[.components[]? | select(.name=="openclaw") | .version] | unique | first' "$repo_dir/sboms/openclaw-v1.cdx.json")
digest=$(oc -n ai-email-demo get istag/openclaw:v1 -o jsonpath='{.image.metadata.name}')
cat >"$work_dir/presenter-summary.md" <<EOF
# Single-candidate supply-chain stage

- Source: \`versions/v1\`
- Current image component: \`openclaw@$version\`
- Remediation target: \`openclaw@2026.8.2\`
- Image digest: \`$digest\`

The presenter updates the same v1 dependency and lockfile. The pipeline rebuilds,
generates the final-image SBOM, signs the digest, applies RHACS image and
deployment gates, and promotes the approved digest as v1 and latest.
EOF
echo "Presentation evidence ready: make show"
