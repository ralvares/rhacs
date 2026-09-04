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

old_pvc_uid=$(oc -n "$app_namespace" get pvc openclaw-state -o jsonpath='{.metadata.uid}')

# Keep the Deployment identity so RHACS retains the learned process and network
# baselines. Pause the rollout, stop v1, and replace its state volume before v2
# can start. The maintained release therefore never mounts or migrates v1 data.
oc -n "$app_namespace" rollout pause deployment/openclaw
resume_deployment() {
  oc -n "$app_namespace" rollout resume deployment/openclaw >/dev/null 2>&1 || true
}
trap resume_deployment EXIT

oc -n "$app_namespace" set image deployment/openclaw \
  prepare-openclaw-home="$image" \
  prepare-openclaw-state="$image" \
  configure-exec-approvals="$image" \
  openclaw="$image"
oc -n "$app_namespace" annotate deployment/openclaw \
  demo.rhacs.ai/release=v2 \
  demo.rhacs.ai/pipeline-run="$run" \
  demo.rhacs.ai/immutable-image="$image" --overwrite

echo "Stopping v1 before replacing its state volume..."
oc -n "$app_namespace" scale deployment/openclaw --replicas=0
oc -n "$app_namespace" wait --for=delete pod -l app=openclaw --timeout=180s 2>/dev/null || \
  [ -z "$(oc -n "$app_namespace" get pod -l app=openclaw -o name)" ]
oc -n "$app_namespace" delete pvc openclaw-state --wait=true
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openclaw-state
  namespace: ai-email-demo
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF
new_pvc_uid=$(oc -n "$app_namespace" get pvc openclaw-state -o jsonpath='{.metadata.uid}')
[ "$new_pvc_uid" != "$old_pvc_uid" ] || {
  echo "OpenClaw state PVC was not replaced." >&2
  exit 1
}

oc -n "$app_namespace" rollout resume deployment/openclaw
trap - EXIT
oc -n "$app_namespace" scale deployment/openclaw --replicas=1
oc -n "$app_namespace" rollout status deployment/openclaw --timeout=300s

echo
echo "APPROVED: RHACS admission accepted the signed, maintained v2 digest."
echo "OpenClaw v2 is healthy on a fresh PVC; no v1 state was migrated."
echo "Open the browser, click Connect, then run make credentials to approve its v2 device request."
