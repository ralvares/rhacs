#!/usr/bin/env bash
set -euo pipefail

namespace=demo-platform
app_namespace=ai-email-demo
run=$(oc -n "$namespace" get pipelineruns \
  -l 'app.kubernetes.io/name=openclaw-release,demo.rhacs.ai/presentation=v2-approved' \
  --sort-by=.metadata.creationTimestamp -o json | jq -r '.items[-1].metadata.name // empty')
[ -n "$run" ] || { echo "No pre-approved v2 PipelineRun is staged. Run make demo-reset." >&2; exit 1; }

run_json=$(oc -n "$namespace" get pipelinerun "$run" -o json)
status=$(jq -r '.status.conditions[0].status // "Unknown"' <<<"$run_json")
[ "$status" = True ] || { echo "The staged v2 PipelineRun is not successful: $run" >&2; exit 1; }
image=$(jq -r '.metadata.annotations["demo.rhacs.ai/immutable-image"] // empty' <<<"$run_json")
[ -n "$image" ] || { echo "The staged v2 digest is missing." >&2; exit 1; }

cat <<EOF
RHACS ADMISSION DEMO
  Candidate: OpenClaw v2 (openclaw@2026.8.2)
  Evidence:  signed image, passed component policy, passed deployment check
  Digest:    $image

Submitting the immutable v2 workload to OpenShift admission...
EOF

oc -n "$app_namespace" set image deployment/openclaw \
  prepare-openclaw-home="$image" \
  prepare-openclaw-state="$image" \
  openclaw="$image"
oc -n "$app_namespace" annotate deployment/openclaw \
  demo.rhacs.ai/release=v2 \
  demo.rhacs.ai/pipeline-run="$run" \
  demo.rhacs.ai/immutable-image="$image" --overwrite
oc -n "$app_namespace" rollout status deployment/openclaw --timeout=300s

echo
echo "APPROVED: RHACS admission accepted the signed, maintained v2 digest."
echo "OpenClaw v2 is healthy and ready for the runtime email demonstration."
