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
        total=$((total + $(jq '[.alerts[]? | select(
          .state == "ACTIVE" and
          .policy.name != "Demo - Critical OpenClaw release blocked" and
          .policy.name != "Demo - Unsigned OpenClaw release blocked"
        )] | length' <<<"$alerts")))
    done
    printf '%s\n' "$total"
}

delete_demo_gates() {
    local policy_name policy_id policies
    oc -n stackrox delete securitypolicy \
        demo-unsigned-openclaw-release-blocked \
        demo-critical-openclaw-release-blocked \
        --ignore-not-found --wait=true >/dev/null
    for policy_name in \
        "Demo - Unsigned OpenClaw release blocked" \
        "Demo - Critical OpenClaw release blocked"; do
        policy_id=$(central_api GET /v1/policies | jq -r --arg name "$policy_name" \
            '.policies[]? | select(.name == $name) | .id' | head -n 1)
        [ -n "$policy_id" ] || continue
        central_api DELETE "/v1/policies/$policy_id" >/dev/null
        echo "Deleted reset-time policy: $policy_name"
    done
    for _ in $(seq 1 30); do
        policies=$(central_api GET /v1/policies)
        if ! jq -e --arg signature "Demo - Unsigned OpenClaw release blocked" \
            --arg version "Demo - Critical OpenClaw release blocked" \
            '.policies[]? | select(.name == $signature or .name == $version)' \
            <<<"$policies" >/dev/null; then
            return 0
        fi
        sleep 2
    done
    echo "The custom RHACS policies were not removed before the rebuild window." >&2
    return 1
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

"$repo_dir/scripts/cleanup-demo-artifacts.sh" --all
# Remove the EventListener and route before the repository seed push. The
# complete trigger manifest is applied again only after Gitea is clean.
oc delete -f "$repo_dir/deploy/pipelines/30-trigger.yaml" --ignore-not-found --wait=true >/dev/null 2>&1 || true

echo "[1/11] Removing the two custom gates before rebuilding the affected v1 workload..."
delete_demo_gates

echo "[2/11] Resolving runtime alerts attached to the previous demo identities..."
resolved_before=$(resolve_demo_alerts)
echo "Resolved $resolved_before runtime alert(s); deployment findings retire with their old identities."

echo "[3/11] Deleting every application Deployment so OpenShift and RHACS receive new identities..."
oc -n external-sender delete job external-html-sender callback-html-sender --ignore-not-found >/dev/null 2>&1 || true
for namespace in ai-email-demo demo-webhook; do
    if oc get namespace "$namespace" >/dev/null 2>&1; then
        oc -n "$namespace" delete deployment --all --ignore-not-found --wait=true --timeout=5m
    fi
done

echo "[4/11] Recreating the affected v1 workload from staged images..."
DEMO_SKIP_CHAT_SMOKE_TEST=true OPENSHIFT_REBUILD_IMAGES=false \
    "$repo_dir/scripts/setup.sh" openshift

echo "[5/11] Re-enabling RHACS gates, registry access, base images, and baselines..."
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

echo "[6/11] Refreshing the cached affected-v1 RHACS evidence used during the presentation..."
echo "Scoping generic deployment-noise policies away from the demo namespaces..."
reconcile_clean_demo_exclusions
"$repo_dir/scripts/prepare-supply-chain-demo.sh"

echo "[7/11] Waiting for Sensor to settle, then clearing alerts from the reset itself..."
sleep 5
resolved_after=$(resolve_demo_alerts)
echo "Resolved $resolved_after reset-time alert(s); final retirement is checked after workspace staging."

echo "[8/11] Verifying workloads, policies, base-image configuration, and baselines..."
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

echo "[9/11] Resetting Gitea, webhook delivery, Dev Spaces, and pipeline resources..."
DEMO_REBUILD_WORKSTATION=false DEMO_RECREATE_GITEA_REPOSITORY=true \
    "$repo_dir/scripts/setup-pipelines.sh"

echo "[10/11] Staging the failed-v1 and approved-v2 PipelineRuns for the presentation..."
"$repo_dir/scripts/stage-affected-pipeline.sh"
"$repo_dir/scripts/stage-approved-pipeline.sh"

echo "Enabling RHACS deployment-create admission after both candidate decisions are cached..."
"$repo_dir/scripts/rhacs/configure-signature-policy.sh"

pipeline_runs=$(oc -n demo-platform get pipelineruns \
    -l app.kubernetes.io/name=openclaw-release -o json)
pipeline_run_count=$(jq '.items | length' <<<"$pipeline_runs")
[ "$pipeline_run_count" -eq 2 ] || {
    echo "Expected exactly two presentation PipelineRuns; found $pipeline_run_count." >&2
    exit 1
}
pipeline_run=$(jq -r '.items[] | select(.status.conditions[0].status == "False") | .metadata.name' <<<"$pipeline_runs")
gate_pod=$(oc -n demo-platform get taskrun \
    -l "tekton.dev/pipelineRun=${pipeline_run},tekton.dev/pipelineTask=rhacs-image-check" \
    -o jsonpath='{.items[0].status.podName}')
[ -n "$gate_pod" ] || { echo "RHACS image-check Task pod was not recorded." >&2; exit 1; }
oc -n demo-platform logs "$gate_pod" --all-containers --prefix >/dev/null 2>&1 || {
    echo "RHACS image-check logs are not retained for $gate_pod." >&2
    exit 1
}
echo "RHACS image-check logs retained in pod: $gate_pod"

# The OpenShift console also reads Tekton Results. A clean Kubernetes API is
# not sufficient if older archived records remain in that database.
postgres=$(oc -n openshift-pipelines get pod \
    -l app.kubernetes.io/name=tekton-results-postgres \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$postgres" ]; then
    result_count=$(oc -n openshift-pipelines exec "$postgres" -- sh -lc \
      "PGPASSWORD=\"\$POSTGRESQL_PASSWORD\" psql -U \"\$POSTGRESQL_USER\" -d \"\$POSTGRESQL_DATABASE\" -Atc \"SELECT count(*) FROM results WHERE parent = 'demo-platform';\"")
    [ "$result_count" -eq 2 ] || {
        echo "Expected exactly two Tekton Results entries; found $result_count." >&2
        exit 1
    }
    echo "Tekton Results contains exactly two presentation runs."
fi

# Workspace startup and the staged pipeline can produce late reset-time events
# after the earlier cleanup. Resolve that bounded set once, then use only
# read-only convergence checks while Sensor retires the old identities.
resolved_final=$(resolve_demo_alerts)
echo "Resolved $resolved_final late reset-time alert(s) before final convergence."
zero_checks=0
remaining_alerts=0
for _ in $(seq 1 36); do
    remaining_alerts=$(active_demo_alert_count)
    if [ "$remaining_alerts" -eq 0 ]; then
        zero_checks=$((zero_checks + 1))
        [ "$zero_checks" -ge 2 ] && break
    else
        zero_checks=0
    fi
    sleep 5
done
[ "$remaining_alerts" -eq 0 ] || {
    echo "The demo still has $remaining_alerts active RHACS alert(s) after final convergence." >&2
    exit 1
}
echo "[11/11] Verified zero unexpected active alerts after final convergence."

echo
echo "Fresh demo environment is ready."
echo "  - all application Deployments were deleted and recreated"
echo "  - RHACS Central and Scanner data were preserved"
echo "  - internal-registry integration and approved base images were reconciled"
echo "  - component-version, signature, and file-activity policies were reconciled"
echo "  - process and network baselines were rebuilt for the new deployment identities"
echo "  - cached affected-v1 evidence was refreshed"
echo "  - Gitea was force-reset to one signed source commit for the affected v1 code"
echo "  - Dev Spaces was recreated with the tested RHDA and terminal environment"
echo "  - one rejected v1 and one approved-but-not-deployed v2 PipelineRun were staged"
echo "  - RHACS deployment admission is enabled for the final one-command v2 promotion"
echo "  - mailbox, OpenClaw sessions, receiver evidence, and egress state are clean"
echo "  - unexpected active alerts in the three demo namespaces: 0"
echo "  - the two intentional v1 deploy findings remain visible in RHACS"
echo
CLI=oc "$repo_dir/scripts/show-demo-credentials.sh"
