#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
namespace=demo-platform

run_name=$(DEMO_SOURCE_VERSION=v2 DEMO_SIGN_CANDIDATE=true DEMO_PROMOTE_CANDIDATE=false DEMO_REUSE_EXISTING_IMAGE=true \
  "$repo_dir/scripts/run-pipeline.sh" | awk '/pipelinerun.tekton.dev\// {name=$1; sub(/^.*\//, "", name); print name; exit}')
[ -n "$run_name" ] || { echo "The approved v2 PipelineRun was not created." >&2; exit 1; }

echo "Waiting for the prebuilt, signed v2 release evidence: $run_name"
for _ in $(seq 1 180); do
  status=$(oc -n "$namespace" get pipelinerun "$run_name" \
    -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
  [ "$status" = True ] && break
  if [ "$status" = False ]; then
    oc -n "$namespace" get pipelinerun "$run_name" \
      -o jsonpath='{.status.conditions[0].message}{"\n"}' >&2
    exit 1
  fi
  sleep 5
done
[ "${status:-}" = True ] || { echo "The v2 PipelineRun did not complete." >&2; exit 1; }

run_json=$(oc -n "$namespace" get pipelinerun "$run_name" -o json)
image=$(jq -r '.status.results[]? | select(.name == "image") | .value' <<<"$run_json")
[ -n "$image" ] && [ "$image" != null ] || { echo "The v2 immutable image result is missing." >&2; exit 1; }
image_tag=$(jq -r '.spec.params[] | select(.name == "image-tag") | .value' <<<"$run_json")
oc -n ai-email-demo tag "openclaw:${image_tag}" openclaw:v2 >/dev/null
oc -n "$namespace" label pipelinerun "$run_name" \
  demo.rhacs.ai/presentation=v2-approved --overwrite >/dev/null
oc -n "$namespace" annotate pipelinerun "$run_name" \
  demo.rhacs.ai/immutable-image="$image" --overwrite >/dev/null

echo "Approved v2 pipeline evidence is staged: $run_name"
echo "Immutable candidate: $image"
echo "The candidate is tagged openclaw:v2 but is not deployed."
