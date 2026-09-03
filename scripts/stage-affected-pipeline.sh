#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
namespace=demo-platform

run_name=$(DEMO_SOURCE_VERSION=v1 DEMO_SIGN_CANDIDATE=false DEMO_PROMOTE_CANDIDATE=false DEMO_REUSE_EXISTING_IMAGE=true \
  "$repo_dir/scripts/run-pipeline.sh" | awk '/pipelinerun.tekton.dev\// {name=$1; sub(/^.*\//, "", name); print name; exit}')
[ -n "$run_name" ] || {
  echo "The affected presentation PipelineRun was not created." >&2
  exit 1
}

echo "Waiting for the intentionally affected v1 release gate: $run_name"
for _ in $(seq 1 120); do
  status=$(oc -n "$namespace" get pipelinerun "$run_name" \
    -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
  [ "$status" = False ] && break
  if [ "$status" = True ]; then
    echo "The v1 presentation run unexpectedly passed." >&2
    exit 1
  fi
  sleep 5
done

[ "${status:-}" = False ] || {
  echo "The v1 presentation run did not reach the expected failed gate." >&2
  exit 1
}
gate_status=$(oc -n "$namespace" get taskrun \
  -l "tekton.dev/pipelineRun=${run_name},tekton.dev/pipelineTask=rhacs-image-check" \
  -o jsonpath='{.items[0].status.conditions[0].status}' 2>/dev/null || true)
[ "$gate_status" = False ] || {
  message=$(oc -n "$namespace" get pipelinerun "$run_name" \
    -o jsonpath='{.status.conditions[0].message}')
  echo "The run failed outside the expected RHACS image gate: $message" >&2
  exit 1
}

gate_pod=$(oc -n "$namespace" get taskrun \
  -l "tekton.dev/pipelineRun=${run_name},tekton.dev/pipelineTask=rhacs-image-check" \
  -o jsonpath='{.items[0].status.podName}')
gate_log=$(oc -n "$namespace" logs "$gate_pod" --all-containers=true 2>/dev/null || true)
for expected_policy in \
  "Demo - Critical OpenClaw release blocked" \
  "Demo - Unsigned OpenClaw release blocked"; do
  grep -F "$expected_policy" <<<"$gate_log" >/dev/null || {
    echo "The opening v1 gate did not report: $expected_policy" >&2
    exit 1
  }
done

oc -n "$namespace" label pipelinerun "$run_name" \
  demo.rhacs.ai/presentation=v1-rejected --overwrite >/dev/null

echo "Affected and unsigned v1 pipeline evidence is staged: $run_name"
