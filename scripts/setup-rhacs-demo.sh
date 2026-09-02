#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rhacs_env="$repo_dir/.rhacs.env"
install_mode=auto
prepare_demo=true

usage() {
    cat <<'EOF'
usage: ./scripts/setup-rhacs-demo.sh [--install|--skip-install] [--skip-demo-reset]

Installs RHACS when needed, configures access to the OpenShift internal image
registry, enables the runtime deviation policies, resets the application to its
clean state, signs the immutable v2 image, configures the scoped RHACS
signature policy, and locks the demo process/network baselines.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --install) install_mode=yes ;;
        --skip-install) install_mode=no ;;
        --skip-demo-reset) prepare_demo=false ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

for command_name in oc curl jq; do
    command -v "$command_name" >/dev/null 2>&1 || { echo "$command_name is required" >&2; exit 1; }
done

if [ -f "$rhacs_env" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$rhacs_env"
    set +a
fi

if ! oc -n stackrox get central stackrox-central-services >/dev/null 2>&1; then
    if [ "$install_mode" = no ]; then
        echo "RHACS Central is not installed and --skip-install was selected" >&2
        exit 1
    fi
    "$repo_dir/scripts/rhacs/deploy.sh" --install
elif [ "$install_mode" = yes ]; then
    "$repo_dir/scripts/rhacs/deploy.sh" --install
else
    echo "RHACS Central is already installed."
fi

central_host=$(oc -n stackrox get route central -o jsonpath='{.spec.host}')
export ROX_ENDPOINT=${ROX_ENDPOINT:-${central_host}:443}

secured_cluster_name=$(oc -n stackrox get securedclusters.platform.stackrox.io -o json | jq -r \
    '.items[]? | select(.spec.clusterName == "production") | .metadata.name' | head -1)
[ -n "$secured_cluster_name" ] || { echo "RHACS SecuredCluster for production was not found" >&2; exit 1; }
fam_mode=$(oc -n stackrox get securedcluster "$secured_cluster_name" -o jsonpath='{.spec.perNode.fileActivityMonitoring.mode}')
[ "$fam_mode" = Enabled ] || {
    echo "File Activity Monitoring is not enabled on SecuredCluster/$secured_cluster_name" >&2
    exit 1
}
fact_ready=false
for _ in $(seq 1 60); do
    if oc -n stackrox get ds collector -o json | jq -e '
        (.spec.template.spec.containers | any(.name == "fact")) and
        (.status.numberReady == .status.desiredNumberScheduled) and
        (.status.desiredNumberScheduled > 0)' >/dev/null; then
        fact_ready=true
        break
    fi
    sleep 5
done
[ "$fact_ready" = true ] || { echo "RHACS Collector fact container is not ready" >&2; exit 1; }
echo "File Activity Monitoring: Enabled; Collector fact container ready."

api_auth=()
if [ -n "${ROX_API_TOKEN:-}" ]; then
    api_auth=(-H "Authorization: Bearer $ROX_API_TOKEN")
else
    admin_password=$(oc -n stackrox get secret central-htpasswd -o jsonpath='{.data.password}' | base64 -d)
    api_auth=(-u "admin:${admin_password}")
fi

central_api() {
    local method=$1 api_path=$2 body=${3:-}
    local args=(-ksS -X "$method" "${api_auth[@]}" -H 'Content-Type: application/json')
    [ -n "$body" ] && args+=(-d "$body")
    curl "${args[@]}" "https://${central_host}${api_path}"
}

if [ -z "${ROX_API_TOKEN:-}" ]; then
    token_response=$(central_api POST /v1/apitokens/generate \
        '{"name":"ai-email-demo-baselines","role":"Admin"}')
    export ROX_API_TOKEN=$(jq -r '.token // empty' <<<"$token_response")
    [ -n "$ROX_API_TOKEN" ] || {
        echo "Could not generate the RHACS demo API token" >&2
        jq . <<<"$token_response" >&2
        exit 1
    }
    umask 077
    {
        printf 'ROX_ENDPOINT=%q\n' "$ROX_ENDPOINT"
        printf 'ROX_API_TOKEN=%q\n' "$ROX_API_TOKEN"
        case "$ROX_ENDPOINT" in
            *.apps-crc.testing|*.apps-crc.testing:*)
                printf 'ROX_INSECURE_CLIENT_SKIP_TLS_VERIFY=true\n'
                ;;
        esac
    } > "$rhacs_env"
    echo "Created $rhacs_env with mode 600. It is excluded from source control."
    api_auth=(-H "Authorization: Bearer $ROX_API_TOKEN")
fi

echo "Configuring RHACS access to the OpenShift internal registry..."
ROX_ENDPOINT="$ROX_ENDPOINT" ROX_API_TOKEN="$ROX_API_TOKEN" \
    "$repo_dir/scripts/rhacs/configure-internal-registry.sh"

echo "Registering the workload's approved UBI base images..."
ROX_ENDPOINT="$ROX_ENDPOINT" ROX_API_TOKEN="$ROX_API_TOKEN" \
    "$repo_dir/scripts/rhacs/configure-base-images.sh"

echo "Signing the immutable v2 image inside CRC..."
"$repo_dir/scripts/sign-release-v2.sh"

echo "Configuring RHACS affected-component and signature verification gates..."
ROX_ENDPOINT="$ROX_ENDPOINT" ROX_API_TOKEN="$ROX_API_TOKEN" \
    "$repo_dir/scripts/rhacs/configure-signature-policy.sh"

require_detect_only_policy() {
    local policy_name=$1 policy_id policy disabled enforcement_count
    policy_id=$(central_api GET /v1/policies | jq -r --arg name "$policy_name" \
        '.policies[]? | select(.name == $name) | .id' | head -1)
    [ -n "$policy_id" ] || { echo "RHACS policy not found: $policy_name" >&2; return 1; }
    policy=$(central_api GET "/v1/policies/$policy_id")
    disabled=$(jq -r '.disabled // false' <<<"$policy")
    enforcement_count=$(jq '(.enforcementActions // []) | length' <<<"$policy")
    [ "$disabled" = false ] || {
        echo "RHACS policy is disabled; refusing to modify cluster-wide policy: $policy_name" >&2
        return 1
    }
    [ "$enforcement_count" -eq 0 ] || {
        echo "RHACS policy has enforcement actions; refusing to weaken cluster-wide policy: $policy_name" >&2
        return 1
    }
    echo "Verified existing detect-only policy without changing it: $policy_name"
}

require_detect_only_policy "Unauthorized Process Execution"
require_detect_only_policy "Unauthorized Network Flow"

echo "Configuring the scoped file-activity policy..."
ROX_ENDPOINT="$ROX_ENDPOINT" ROX_API_TOKEN="$ROX_API_TOKEN" \
    "$repo_dir/scripts/rhacs/configure-file-activity-policy.sh"

if [ "$prepare_demo" = true ]; then
    echo "Resetting the application to the clean presentation state..."
    "$repo_dir/scripts/setup-demo.sh" >/dev/null
fi

echo "Waiting for RHACS to inventory the demo deployments..."
# shellcheck disable=SC1091
source "$repo_dir/scripts/rhacs-baselines.sh"
targets=(
    ai-email-demo/openclaw
    ai-email-demo/mail-server
    ai-email-demo/mail-api
    ai-email-demo/webmail
    ai-email-demo/unauthorized-demo-service
    ai-email-demo/approved-internal-service
    demo-webhook/demo-webhook
)
for target in "${targets[@]}"; do
    ready=false
    for _ in $(seq 1 60); do
        if _roxb_resolve "$target" >/dev/null 2>&1; then ready=true; break; fi
        sleep 5
    done
    [ "$ready" = true ] || { echo "RHACS did not inventory $target before timeout" >&2; exit 1; }
done

echo "Locking current process baselines for the application..."
for target in "${targets[@]}"; do
    rhacs-pb-lock "$target"
done

# Declare the stable startup/runtime processes for every presentation workload.
# This removes the timing dependency between pod readiness, Sensor ingestion,
# and locking on a fast single-node CRC. These are expected application paths,
# not attack tooling; curl remains deliberately absent.
rhacs-pb-add ai-email-demo/mail-server greenmail \
    /home/greenmail/run_greenmail.sh /usr/bin/java
rhacs-pb-add ai-email-demo/mail-api mail-api \
    /usr/bin/container-entrypoint /usr/bin/uname /opt/app-root/bin/uvicorn
rhacs-pb-add ai-email-demo/webmail roundcube \
    /docker-entrypoint.sh /usr/bin/base64 /usr/bin/chown /usr/bin/dirname \
    /usr/bin/grep /usr/bin/head /usr/bin/ls /usr/bin/mkdir /usr/bin/rm \
    /usr/bin/sed /usr/bin/tar /usr/local/bin/apache2-foreground \
    /usr/local/bin/php /usr/sbin/apache2 /var/www/html/bin/initdb.sh \
    chown mkdir touch
for sink_target in ai-email-demo/unauthorized-demo-service ai-email-demo/approved-internal-service; do
    rhacs-pb-add "$sink_target" sink \
        /usr/bin/container-entrypoint /usr/bin/uname /opt/app-root/bin/uvicorn
done
rhacs-pb-add demo-webhook/demo-webhook webhook \
    /usr/bin/container-entrypoint /usr/bin/uname /opt/app-root/bin/uvicorn \
    /opt/app-root/bin/python /usr/bin/sh

# Preserve RHACS's learned clean-run history, then add only stable processes
# needed before every rehearsal. curl is deliberately excluded, even if an
# earlier rehearsal taught it to RHACS. The history report makes the difference
# between sensor-learned, explicitly declared, and removed entries visible.
echo "Agent process history before reconciliation:"
rhacs-pb-history ai-email-demo/openclaw
rhacs-pb-add ai-email-demo/openclaw openclaw \
    /usr/local/bin/node /usr/bin/node /usr/bin/node-22 /usr/bin/python3 \
    /bin/sh /usr/bin/sh /usr/bin/cat /usr/bin/find /usr/bin/readlink \
    /usr/bin/rm /usr/bin/sed /usr/bin/id /usr/bin/hostnamectl /usr/bin/uname \
    /usr/libexec/grepconf.sh grepconf.sh /usr/bin/grep /usr/bin/xargs \
    /usr/bin/tr /usr/bin/locale /usr/bin/tclsh /bin/ps \
    /bin/basename /usr/bin/basename
rhacs-pb-remove ai-email-demo/openclaw openclaw /usr/bin/curl /usr/local/bin/curl
rhacs-pb-lock ai-email-demo/openclaw
echo "Agent process baseline after reconciliation:"
rhacs-pb-history ai-email-demo/openclaw

echo "Auditing observed process history against every locked baseline..."
for target in "${targets[@]}"; do
    rhacs-pb-lock "$target"
    rhacs-pb-audit "$target"
done

echo "Declaring and locking the agent's expected network behavior..."
# Normal Route ingress is observed as the OpenShift router deployment.
rhacs-nb-add ai-email-demo/openclaw --peer openshift-ingress/router-default --port 8080 --ingress
# CRC exposes the workstation model through host networking, which RHACS
# classifies as INTERNAL_ENTITIES rather than INTERNET.
rhacs-nb-add ai-email-demo/openclaw --peer internal --port 11434
# OpenShift node-local DNS normally uses UDP 5353; TCP is a valid fallback.
rhacs-nb-add ai-email-demo/openclaw --peer openshift-dns/dns-default --port 5353 --udp
rhacs-nb-add ai-email-demo/openclaw --peer openshift-dns/dns-default --port 5353
rhacs-nb-add ai-email-demo/openclaw --peer ai-email-demo/mail-server --port 3143
rhacs-nb-add ai-email-demo/openclaw --peer ai-email-demo/approved-internal-service --port 8080
rhacs-nb-add ai-email-demo/openclaw --peer internal --port 8080 --ingress
# Remove obsolete/broad declarations from earlier revisions.
rhacs-nb-remove ai-email-demo/openclaw --peer internet --port 11434
rhacs-nb-remove ai-email-demo/openclaw --peer demo-webhook/demo-webhook --port 8080
rhacs-nb-forbid-external ai-email-demo/openclaw
rhacs-nb-lock ai-email-demo/openclaw

echo "Declaring the complete application network contract..."
# Mail server: SMTP from mail-api, IMAP from mail-api/webmail/agent, plus CRC
# platform health traffic. It initiates no application egress.
rhacs-nb-add ai-email-demo/mail-server --peer ai-email-demo/mail-api --port 3025 --ingress
rhacs-nb-add ai-email-demo/mail-server --peer ai-email-demo/mail-api --port 3143 --ingress
rhacs-nb-add ai-email-demo/mail-server --peer ai-email-demo/webmail --port 3143 --ingress
rhacs-nb-add ai-email-demo/mail-server --peer ai-email-demo/openclaw --port 3143 --ingress
rhacs-nb-add ai-email-demo/mail-server --peer internal --port 3025 --ingress
rhacs-nb-add ai-email-demo/mail-server --peer internal --port 3143 --ingress
rhacs-nb-forbid-external ai-email-demo/mail-server
rhacs-nb-lock ai-email-demo/mail-server

# Mail API: Route/platform ingress, SMTP+IMAP to GreenMail, and cluster DNS.
rhacs-nb-add ai-email-demo/mail-api --peer openshift-ingress/router-default --port 8080 --ingress
rhacs-nb-add ai-email-demo/mail-api --peer internal --port 8080 --ingress
rhacs-nb-add ai-email-demo/mail-api --peer ai-email-demo/mail-server --port 3025
rhacs-nb-add ai-email-demo/mail-api --peer ai-email-demo/mail-server --port 3143
rhacs-nb-add ai-email-demo/mail-api --peer openshift-dns/dns-default --port 5353 --udp
rhacs-nb-add ai-email-demo/mail-api --peer openshift-dns/dns-default --port 5353
rhacs-nb-forbid-external ai-email-demo/mail-api
rhacs-nb-lock ai-email-demo/mail-api

# Webmail: Route/platform ingress, IMAP, and cluster DNS.
rhacs-nb-add ai-email-demo/webmail --peer openshift-ingress/router-default --port 8000 --ingress
rhacs-nb-add ai-email-demo/webmail --peer internal --port 8000 --ingress
rhacs-nb-add ai-email-demo/webmail --peer ai-email-demo/mail-server --port 3143
rhacs-nb-add ai-email-demo/webmail --peer openshift-dns/dns-default --port 5353 --udp
rhacs-nb-add ai-email-demo/webmail --peer openshift-dns/dns-default --port 5353
rhacs-nb-forbid-external ai-email-demo/webmail
rhacs-nb-lock ai-email-demo/webmail

# Approved service is reachable from the agent. The unused local sink and the
# isolated receiver allow platform health traffic only. The receiver flow from
# the agent is explicitly anomalous in both deployments.
rhacs-nb-add ai-email-demo/approved-internal-service --peer ai-email-demo/openclaw --port 8080 --ingress
rhacs-nb-add ai-email-demo/approved-internal-service --peer internal --port 8080 --ingress
rhacs-nb-forbid-external ai-email-demo/approved-internal-service
rhacs-nb-lock ai-email-demo/approved-internal-service

rhacs-nb-add ai-email-demo/unauthorized-demo-service --peer internal --port 8080 --ingress
rhacs-nb-remove ai-email-demo/unauthorized-demo-service --peer ai-email-demo/openclaw --port 8080 --ingress
rhacs-nb-forbid-external ai-email-demo/unauthorized-demo-service
rhacs-nb-lock ai-email-demo/unauthorized-demo-service

rhacs-nb-add demo-webhook/demo-webhook --peer internal --port 8080 --ingress
rhacs-nb-add demo-webhook/demo-webhook --peer openshift-ingress/router-default --port 8080 --ingress
rhacs-nb-remove demo-webhook/demo-webhook --peer ai-email-demo/openclaw --port 8080 --ingress
rhacs-nb-forbid-external demo-webhook/demo-webhook
rhacs-nb-lock demo-webhook/demo-webhook

echo "Resolving stale deviation alerts from earlier rehearsals..."
resolve_runtime_demo_alerts() {
    local alerts alert_id namespace
    for namespace in ai-email-demo demo-webhook external-sender; do
        alerts=$(central_api GET "/v1/alerts?query=Namespace%3A${namespace}")
        while IFS= read -r alert_id; do
            [ -n "$alert_id" ] || continue
            central_api PATCH "/v1/alerts/$alert_id/resolve" '{}' >/dev/null
        done < <(jq -r '.alerts[]? | select(
            .state == "ACTIVE" and
            (.policy.name == "Unauthorized Process Execution" or
             .policy.name == "Unauthorized Network Flow" or
             .policy.name == "Demo - Unexpected Runtime Artifact" or
             .policy.name == "Demo - Sensitive File Transfer via curl" or
             .policy.name == "Kubernetes Actions: Exec into Pod")
          ) | .id' <<<"$alerts")
    done
}

resolve_runtime_demo_alerts
# Sensor and baseline events are asynchronous. Give a single-node CRC a short
# settling window and resolve only the named demo policies again so the talk
# starts at a genuine zero-alert runtime baseline.
for _ in 1 2 3; do
    sleep 5
    resolve_runtime_demo_alerts
done

echo
echo "RHACS demo setup is complete."
echo "Central: https://${central_host}"
echo "Registry: connected and scoped to ai-email-demo"
echo "Policies: Unauthorized Process Execution and Unauthorized Network Flow enabled"
echo "Signature: registry-backed v2 digest verified; scoped RHACS build/deploy policy enabled"
echo "Policy: path/operation-only runtime artifact detection enabled for ai-email-demo"
echo "File activity: enabled in SecuredCluster (RHACS 4.11 Technology Preview)"
echo "Agent: router ingress, DNS, IMAP, and CRC-host model traffic baselined"
echo "Agent: curl and demo-webhook:8080 remain excluded"
echo "Network: all seven workload baselines locked; direct external peers forbidden"
echo "Alerts: stale process/network deviations resolved for a clean runtime act"
echo
echo "Verify at any time:"
echo "  make rhacs-baseline-status"
echo "  make rhacs-network-status"
