#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rhacs_env="$repo_dir/.rhacs.env"

for command_name in oc curl jq; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "$command_name is required" >&2
        exit 1
    }
done

oc -n stackrox get central stackrox-central-services >/dev/null 2>&1 || {
    echo "RHACS Central is required. Run make setup-full for the first installation." >&2
    exit 1
}

central_host=$(oc -n stackrox get route central -o jsonpath='{.spec.host}')
api_auth=()
if [ -f "$rhacs_env" ]; then
    # shellcheck disable=SC1090
    set -a; source "$rhacs_env"; set +a
fi
if [ -n "${ROX_API_TOKEN:-}" ]; then
    api_auth=(-H "Authorization: Bearer $ROX_API_TOKEN")
else
    admin_password=$(oc -n stackrox get secret central-htpasswd -o jsonpath='{.data.password}' | base64 -d)
    api_auth=(-u "admin:${admin_password}")
fi

central_api() {
    local method=$1 api_path=$2 body=${3:-}
    local args=(-kfsS --connect-timeout 5 --max-time 60 -X "$method" "${api_auth[@]}" -H 'Content-Type: application/json')
    [ -n "$body" ] && args+=(-d "$body")
    curl "${args[@]}" "https://${central_host}${api_path}"
}

resolve_demo_alerts() {
    local namespace alerts alert_id resolved=0
    for namespace in ai-email-demo demo-webhook external-sender; do
        alerts=$(central_api GET "/v1/alerts?query=Namespace%3A${namespace}")
        while IFS= read -r alert_id; do
            [ -n "$alert_id" ] || continue
            central_api PATCH "/v1/alerts/$alert_id/resolve" '{}' >/dev/null
            resolved=$((resolved + 1))
        done < <(jq -r '.alerts[]? | select(.state == "ACTIVE" and .lifecycleStage == "RUNTIME") | .id' <<<"$alerts")
    done
    printf '%s\n' "$resolved"
}

active_demo_alert_count() {
    local namespace alerts total=0
    for namespace in ai-email-demo demo-webhook external-sender; do
        alerts=$(central_api GET "/v1/alerts?query=Namespace%3A${namespace}")
        total=$((total + $(jq '[.alerts[]? | select(.state == "ACTIVE")] | length' <<<"$alerts")))
    done
    printf '%s\n' "$total"
}

reconcile_clean_demo_exclusions() {
    local policy_name namespace policy_id policy updated exclusion_name
    while IFS='|' read -r policy_name namespace; do
        [ -n "$policy_name" ] || continue
        policy_id=$(central_api GET /v1/policies | jq -r --arg name "$policy_name" \
            '.policies[]? | select(.name == $name) | .id' | head -n 1)
        [ -n "$policy_id" ] || {
            echo "RHACS policy not found; cannot prepare clean demo: $policy_name" >&2
            return 1
        }
        policy=$(central_api GET "/v1/policies/$policy_id")
        exclusion_name="AI email demo reset: ignore generic $policy_name in $namespace"
        if jq -e --arg name "$exclusion_name" '.exclusions[]? | select(.name == $name)' \
            <<<"$policy" >/dev/null; then
            continue
        fi
        updated=$(jq --arg name "$exclusion_name" --arg namespace "$namespace" '
            .exclusions = ((.exclusions // []) + [{
                name: $name,
                deployment: {
                    name: "",
                    scope: {
                        cluster: "",
                        namespace: $namespace,
                        label: null,
                        clusterLabel: null,
                        namespaceLabel: null
                    }
                },
                image: null,
                expiration: null
            }])' <<<"$policy")
        central_api PUT "/v1/policies/$policy_id" "$updated" >/dev/null
        echo "Scoped generic policy '$policy_name' away from $namespace."
    done <<'EOF'
Latest tag|ai-email-demo
Latest tag|demo-webhook
Red Hat Package Manager in Image|ai-email-demo
Red Hat Package Manager in Image|demo-webhook
Ubuntu Package Manager in Image|ai-email-demo
No CPU request or memory limit specified|ai-email-demo
Pod Service Account Token Automatically Mounted|demo-webhook
EOF
}

echo "This reset recreates every demo Deployment and reconciles RHACS without reinstalling it."
echo "RHACS Central and Scanner data are preserved. Internal-registry images are reused."
echo

echo "[1/7] Resolving runtime alerts attached to the previous demo identities..."
resolved_before=$(resolve_demo_alerts)
echo "Resolved $resolved_before runtime alert(s); deployment findings retire with their old identities."

echo "[2/7] Deleting every application Deployment so OpenShift and RHACS receive new identities..."
oc -n external-sender delete job external-html-sender callback-html-sender --ignore-not-found >/dev/null 2>&1 || true
for namespace in ai-email-demo demo-webhook; do
    if oc get namespace "$namespace" >/dev/null 2>&1; then
        oc -n "$namespace" delete deployment --all --ignore-not-found --wait=true --timeout=5m
    fi
done

echo "[3/7] Recreating the workload from manifests with the existing internal images..."
DEMO_SKIP_CHAT_SMOKE_TEST=true OPENSHIFT_REBUILD_IMAGES=false \
    "$repo_dir/scripts/setup.sh" openshift

echo "[4/7] Reapplying RHACS registry access, base images, policies, and locked baselines..."
env -u ROX_ENDPOINT -u ROX_API_TOKEN \
    "$repo_dir/scripts/setup-rhacs-demo.sh" --skip-install

# setup-rhacs-demo.sh may create or refresh .rhacs.env. Reload it before the
# final Central checks so the reset never depends on stale process state.
if [ -f "$rhacs_env" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$rhacs_env"
    set +a
    if [ -n "${ROX_API_TOKEN:-}" ]; then
        api_auth=(-H "Authorization: Bearer $ROX_API_TOKEN")
    fi
fi

echo "[5/7] Refreshing the cached v1/v2 RHACS evidence used during the presentation..."
echo "Scoping generic deployment-noise policies away from the demo namespaces..."
reconcile_clean_demo_exclusions
"$repo_dir/scripts/prepare-supply-chain-demo.sh"

echo "[6/7] Waiting for Sensor to settle, then clearing alerts from the reset itself..."
resolved_after=0
for _ in 1 2 3; do
    sleep 5
    resolved_now=$(resolve_demo_alerts)
    resolved_after=$((resolved_after + resolved_now))
done
remaining_alerts=$(active_demo_alert_count)
[ "$remaining_alerts" -eq 0 ] || {
    echo "The demo still has $remaining_alerts active RHACS alert(s) after reset." >&2
    exit 1
}
echo "Resolved $resolved_after reset-time alert(s); zero active demo alerts remain."

echo "[7/7] Verifying workloads, policies, base-image configuration, and baselines..."
oc -n ai-email-demo wait --for=condition=Available deployment --all --timeout=180s >/dev/null
oc -n demo-webhook wait --for=condition=Available deployment --all --timeout=180s >/dev/null

# The setup script performs the authoritative policy/base-image configuration.
# These reports prove that Sensor now resolves the newly-created deployments
# and that the clean process and network contracts remain locked.
set -a
# shellcheck disable=SC1090
source "$rhacs_env"
set +a
# shellcheck disable=SC1091
source "$repo_dir/scripts/rhacs-baselines.sh"
rhacs-pb-audit ai-email-demo/openclaw
rhacs-pb-audit demo-webhook/demo-webhook
rhacs-nb-list ai-email-demo/openclaw
rhacs-nb-list demo-webhook/demo-webhook

echo
echo "Fresh demo environment is ready."
echo "  - all application Deployments were deleted and recreated"
echo "  - RHACS Central and Scanner data were preserved"
echo "  - internal-registry integration and approved base images were reconciled"
echo "  - component-version, signature, and file-activity policies were reconciled"
echo "  - process and network baselines were rebuilt for the new deployment identities"
echo "  - cached v1/v2 evidence was refreshed"
echo "  - mailbox, OpenClaw sessions, receiver evidence, and egress state are clean"
echo "  - active alerts in the three demo namespaces: 0"
echo
CLI=oc "$repo_dir/scripts/show-demo-credentials.sh"
