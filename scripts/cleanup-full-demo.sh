#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rhacs_env="$repo_dir/.rhacs.env"
reinstall_rhacs=false

usage() {
    cat <<'EOF'
usage: ./scripts/cleanup-full-demo.sh [--reinstall-rhacs]

By default, resolve the demo's RHACS alerts and remove only the demo
application namespaces and their released volumes. RHACS, its vulnerability
database, integrations, and local API credentials are preserved.

--reinstall-rhacs  Also delete RHACS and its retained volumes. Use only to test
                   the installer; Scanner must rebuild its vulnerability data.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --reinstall-rhacs) reinstall_rhacs=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

for command_name in oc curl jq; do
    command -v "$command_name" >/dev/null 2>&1 || { echo "$command_name is required" >&2; exit 1; }
done

resolve_demo_alerts() {
    if ! oc -n stackrox get route central >/dev/null 2>&1; then
        echo "RHACS is not installed; no demo alerts to resolve."
        return
    fi

    local central_host token response alert_id namespace
    central_host=$(oc -n stackrox get route central -o jsonpath='{.spec.host}')
    token=""
    if [ -f "$rhacs_env" ]; then
        # Load only the generated token; the active cluster route above remains
        # authoritative even if the file came from an older rehearsal.
        token=$(sed -n 's/^ROX_API_TOKEN=//p' "$rhacs_env" | head -1)
    fi
    if [ -z "$token" ]; then
        echo "No local RHACS API token; preserving alerts rather than guessing credentials."
        return
    fi

    echo "Resolving active RHACS alerts owned by the demo namespaces..."
    for namespace in ai-email-demo external-sender demo-webhook; do
        response=$(curl -kfsS --connect-timeout 5 --max-time 30 \
            -H "Authorization: Bearer $token" \
            "https://${central_host}/v1/alerts?query=Namespace%3A${namespace}")
        while IFS= read -r alert_id; do
            [ -n "$alert_id" ] || continue
            curl -kfsS --connect-timeout 5 --max-time 30 -X PATCH \
                -H "Authorization: Bearer $token" \
                -H 'Content-Type: application/json' \
                -d '{}' "https://${central_host}/v1/alerts/${alert_id}/resolve" >/dev/null
        done < <(jq -r '.alerts[]? | select(.state == "ACTIVE") | .id' <<<"$response")
    done
}

resolve_demo_alerts

if [ "$reinstall_rhacs" = true ]; then
    echo "Removing RHACS Central, secured cluster, and operator..."
    "$repo_dir/scripts/rhacs/deploy.sh" --delete
else
    echo "Preserving RHACS and its vulnerability database."
fi

echo "Removing the demo workload, sender, and receiver namespaces..."
oc delete namespace ai-email-demo external-sender demo-webhook \
    --ignore-not-found --wait=true --timeout=10m

echo "Removing released persistent volumes owned by the deleted namespaces..."
while IFS= read -r volume; do
    [ -n "$volume" ] || continue
    oc delete persistentvolume "$volume" --wait=true --timeout=10m
done < <(oc get persistentvolumes -o json | jq -r --arg reinstall_rhacs "$reinstall_rhacs" '
    .items[]
    | select(.status.phase == "Released")
    | select(.spec.claimRef.namespace == "ai-email-demo" or
             .spec.claimRef.namespace == "external-sender" or
             .spec.claimRef.namespace == "demo-webhook" or
             ($reinstall_rhacs == "true" and
              (.spec.claimRef.namespace == "stackrox" or
               .spec.claimRef.namespace == "rhacs-operator")))
    | .metadata.name')

# The token belongs to the Central instance that was just removed. Keeping it
# would make the next installation authenticate with a permanently stale token.
if [ "$reinstall_rhacs" = true ] && [ -f "$rhacs_env" ]; then
    rm -f -- "$rhacs_env"
    echo "Removed stale local RHACS credentials: .rhacs.env"
fi

echo
if [ "$reinstall_rhacs" = true ]; then
    echo "Cold cleanup complete. RHACS CRDs were preserved, but Scanner data must rebuild."
else
    echo "Application cleanup complete. RHACS and Scanner data were preserved."
fi
echo "Recreate and baseline the applications with: ./scripts/setup-full-demo.sh"
