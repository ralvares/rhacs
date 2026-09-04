#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cat <<'EOF'
This prepares the complete OpenShift demonstration:
  1. build and deploy the AI email workload;
  2. install RHACS if it is absent;
  3. connect RHACS to the OpenShift internal registry;
  4. leave v1 unsigned and configure the scoped component-version and signature gates;
  5. verify runtime deviation policies without weakening shared policy;
  6. reset the clean mailbox state and lock the baselines;
  7. cache the supply-chain evidence used during the presentation;
  8. install Dev Spaces, Gitea, and the OpenShift release pipeline.
EOF

"$repo_dir/scripts/setup.sh" openshift
# A full setup always targets RHACS in the currently selected OpenShift
# cluster. Do not let credentials exported for another cluster leak into this
# run; setup-rhacs-demo.sh will load the matching local .rhacs.env when it is
# reusable, or generate a fresh token after a cold install.
env -u ROX_ENDPOINT -u ROX_API_TOKEN "$repo_dir/scripts/setup-rhacs-demo.sh"
"$repo_dir/scripts/prepare-supply-chain-demo.sh"
"$repo_dir/scripts/setup-pipelines.sh"
"$repo_dir/scripts/cleanup-demo-artifacts.sh" --pipeline-history-only
"$repo_dir/scripts/stage-affected-pipeline.sh"
"$repo_dir/scripts/stage-approved-pipeline.sh"
set -a
# shellcheck disable=SC1091
source "$repo_dir/.rhacs.env"
set +a
"$repo_dir/scripts/rhacs/configure-signature-policy.sh"

echo
echo "Full AI workload, developer workspace, pipeline, and RHACS demo is ready."
