#!/usr/bin/env bash
set -euo pipefail

# This repository targets a dedicated single-node CRC presentation cluster.
# Keep only the newest revision of directly-pushed internal images. Imported
# operator/RHACS images are excluded with --all=false, and images referenced by
# live workloads remain protected by the OpenShift image pruner.

for command_name in oc jq; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "$command_name is required" >&2; exit 1; }
done

if oc get builds.build.openshift.io -A -o json 2>/dev/null | \
  jq -e '.items[]? | select(.status.phase == "Running" or .status.phase == "New" or .status.phase == "Pending")' \
  >/dev/null; then
  echo "Refusing to prune while an OpenShift Build is active." >&2
  exit 1
fi

registry_host=$(oc -n openshift-image-registry get route default-route \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)
[ -n "$registry_host" ] || {
  echo "The OpenShift internal-registry default Route is required for image pruning." >&2
  exit 1
}

# Tekton uses one temporary pipeline tag per run, and Cosign's OpenShift
# registry compatibility mode stores signatures and attestations as digest
# tags. A normal tag-revision prune keeps each of those unique tags forever.
# During a full reset no PipelineRuns remain, so retain only the three human
# release tags and the signature/attestation belonging to the approved v2.
if oc -n ai-email-demo get imagestream openclaw >/dev/null 2>&1; then
  v2_digest=$(oc -n ai-email-demo get istag openclaw:v2 \
    -o jsonpath='{.image.metadata.name}' 2>/dev/null || true)
  v2_hex=${v2_digest#sha256:}
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    case "$tag" in
      latest|v1|v2) continue ;;
      "sha256-${v2_hex}.sig"|"sha256-${v2_hex}.att") continue ;;
    esac
    case "$tag" in
      pipeline-*|sha256-*.sig|sha256-*.att)
        oc -n ai-email-demo delete istag "openclaw:${tag}" --ignore-not-found >/dev/null
        ;;
    esac
  done < <(oc -n ai-email-demo get imagestream openclaw -o json | \
    jq -r '.status.tags[]?.tag')
fi

for namespace in ai-email-demo demo-platform demo-webhook; do
  oc get namespace "$namespace" >/dev/null 2>&1 || continue
  echo "Pruning stale directly-built image revisions in $namespace; keeping the newest revision of every tag..."
  prune_log=$(mktemp /tmp/rhacs-ai-image-prune.XXXXXX)
  if ! oc -n "$namespace" adm prune images \
    --all=false \
    --keep-tag-revisions=1 \
    --keep-younger-than=5m \
    --registry-url="https://${registry_host}" \
    --force-insecure \
    --confirm >"$prune_log" 2>&1; then
    cat "$prune_log" >&2
    rm -f "$prune_log"
    exit 1
  fi
  grep '^Summary:' "$prune_log" || echo "Summary: no stale image content found"
  rm -f "$prune_log"
done
