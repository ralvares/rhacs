#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
service_dir="$script_dir/service"
namespace=stackrox
job=stackrox-internal-registry-integration

command -v oc >/dev/null 2>&1 || { echo "oc is required" >&2; exit 1; }
oc -n "$namespace" get central stackrox-central-services >/dev/null 2>&1 || {
    echo "RHACS Central is not installed" >&2
    exit 1
}

echo "Applying the stable RHACS internal-registry identity..."
oc apply -f "$service_dir/stackrox-image-puller.yaml" >/dev/null

echo "Waiting for OpenShift to populate the ServiceAccount token Secret..."
token_ready=false
for _ in $(seq 1 60); do
    if [ -n "$(oc -n "$namespace" get secret stackrox-image-puller-token -o jsonpath='{.data.token}' 2>/dev/null)" ]; then
        token_ready=true
        break
    fi
    sleep 2
done
[ "$token_ready" = true ] || {
    echo "OpenShift did not populate stackrox-image-puller-token" >&2
    exit 1
}

# Job templates are immutable. Recreate only this scoped configuration Job so
# integration testing can be repeated without reinstalling RHACS.
oc -n "$namespace" delete job "$job" --ignore-not-found --wait=true >/dev/null
oc apply -f "$service_dir/internal-registry-integration-job.yaml" >/dev/null

if ! oc -n "$namespace" wait --for=condition=complete "job/$job" --timeout=300s; then
    oc -n "$namespace" logs "job/$job" --all-containers=true || true
    exit 1
fi
oc -n "$namespace" logs "job/$job" --all-containers=true

# Remove the obsolete namespace-local identity only after the stable
# cluster-wide integration completed successfully.
oc -n ai-email-demo delete rolebinding rhacs-registry-reader-image-puller --ignore-not-found >/dev/null
oc -n ai-email-demo delete serviceaccount rhacs-registry-reader --ignore-not-found >/dev/null

echo "RHACS internal-registry integration is ready."
echo "No presenter-time registry credential refresh is required."
