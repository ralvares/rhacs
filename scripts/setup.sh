#!/usr/bin/env sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
platform=${1:-}
roundcube_digest=sha256:740c18c47d60408e7d659e097a8e8a034735fd9f3b4c5d6dc0eb99bdd708a7ba
roundcube_source="docker.io/roundcube/roundcubemail@${roundcube_digest}"
if [ -f "$repo_dir/.env" ]; then
  set -a
  # This is the operator-owned local configuration file.
  . "$repo_dir/.env"
  set +a
fi
usage() {
  echo "usage:" >&2
  echo "  $0 openshift" >&2
  echo "  $0 kubernetes REGISTRY/PROJECT DOMAIN [INGRESS_CLASS]" >&2
  exit 2
}

apply_base() {
  cli=$1
  replacement=$2
  webmail_image=$3
  trusted_proxy=${4:-127.0.0.1}
  inference_api_url=${INFERENCE_API_URL:-http://host.crc.testing:11434}
  inference_api_type=${INFERENCE_API_TYPE:-ollama}
  inference_provider=${INFERENCE_PROVIDER:-ollama}
  inference_model=${INFERENCE_MODEL:-deepseek-v4-flash:cloud}
  inference_model_name=${INFERENCE_MODEL_NAME:-DeepSeek V4 Flash Cloud}
  escape_sed() { printf '%s' "$1" | sed 's/[&|]/\\&/g'; }
  inference_api_url_escaped=$(escape_sed "$inference_api_url")
  inference_api_type_escaped=$(escape_sed "$inference_api_type")
  inference_provider_escaped=$(escape_sed "$inference_provider")
  inference_model_escaped=$(escape_sed "$inference_model")
  inference_model_name_escaped=$(escape_sed "$inference_model_name")
  trusted_proxy_escaped=$(escape_sed "$trusted_proxy")
  for manifest in "$repo_dir"/deploy/base/*.yaml; do
    sed \
      -e "s#IMAGE_REGISTRY/ai-email-demo#$replacement#g" \
      -e "s|INFERENCE_API_URL|$inference_api_url_escaped|g" \
      -e "s|INFERENCE_API_TYPE|$inference_api_type_escaped|g" \
      -e "s|INFERENCE_PROVIDER|$inference_provider_escaped|g" \
      -e "s|INFERENCE_MODEL_NAME|$inference_model_name_escaped|g" \
      -e "s|INFERENCE_MODEL|$inference_model_escaped|g" \
      -e "s|OPENCLAW_TRUSTED_PROXY|$trusted_proxy_escaped|g" \
      -e "s|WEBMAIL_IMAGE|$webmail_image|g" \
      "$manifest" | "$cli" apply -f -
  done
}

apply_runtime_secrets() {
  cli=$1
  command -v openssl >/dev/null 2>&1 || { echo "openssl is required to generate demo credentials" >&2; exit 1; }
  mail_user=${DEMO_MAIL_USER:-demo}
  mail_password=${DEMO_MAIL_PASSWORD:-demo}
  mail_domain=${DEMO_MAIL_DOMAIN:-demo.test}
  mail_address="${mail_user}@${mail_domain}"
  demo_context_id=$(openssl rand -hex 6)
  gateway_token=$(openssl rand -hex 24)
  inference_api_token=${INFERENCE_API_TOKEN:-ollama-local}
  demo_runtime_context="DEMO_API_KEY=synthetic-${demo_context_id}
DEMO_REGION=lab-only"
  greenmail_opts="-Dgreenmail.setup.test.smtp -Dgreenmail.setup.test.imap -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.users=${mail_user}:${mail_password}@${mail_domain} -Dgreenmail.users.login=username"
  "$cli" -n ai-email-demo create secret generic mail-credentials \
    --from-literal=mail-user="$mail_user" \
    --from-literal=mail-password="$mail_password" \
    --from-literal=mail-address="$mail_address" \
    --from-literal=greenmail-opts="$greenmail_opts" \
    --dry-run=client -o yaml | "$cli" apply -f -
  "$cli" -n ai-email-demo create secret generic demo-runtime-context \
    --from-literal=runtime-context="$demo_runtime_context" \
    --dry-run=client -o yaml | "$cli" apply -f -
  "$cli" -n ai-email-demo create secret generic openclaw-credentials \
    --from-literal=gateway-token="$gateway_token" \
    --dry-run=client -o yaml | "$cli" apply -f -
  "$cli" -n ai-email-demo create secret generic inference-credentials \
    --from-literal=api-token="$inference_api_token" \
    --dry-run=client -o yaml | "$cli" apply -f -
}

if [ "$platform" = "openshift" ]; then
  command -v oc >/dev/null 2>&1 || { echo "oc is required" >&2; exit 1; }
  oc apply -f "$repo_dir/deploy/base/00-namespace.yaml"
  apply_runtime_secrets oc
  oc apply -f "$repo_dir/deploy/openshift/buildconfigs.yaml"
  build_if_needed() {
    build_config=$1
    image_tag=$2
    source_dir=$3
    if [ "${OPENSHIFT_REBUILD_IMAGES:-false}" != true ] && \
       oc -n ai-email-demo get "imagestreamtag/$image_tag" >/dev/null 2>&1; then
      echo "Reusing internal-registry image ai-email-demo/$image_tag"
    else
      oc -n ai-email-demo start-build "$build_config" --from-dir="$source_dir" --follow --wait
    fi
  }
  build_if_needed mail-api mail-api:latest "$repo_dir/services/mail-api"
  build_if_needed openclaw-v1 openclaw:v1 "$repo_dir/services/openclaw"
  oc -n ai-email-demo tag openclaw:v1 openclaw:latest
  build_if_needed demo-sink demo-sink:latest "$repo_dir/services/unauthorized-demo-service"
  echo "Importing the approved pinned Roundcube digest into the internal registry..."
  oc -n ai-email-demo import-image webmail:1.7.3-apache-nonroot \
    --from="$roundcube_source" --confirm --reference-policy=local
  webmail_internal="image-registry.openshift-image-registry.svc:5000/ai-email-demo/webmail@${roundcube_digest}"
  # Start closed. After the Route is live, setup learns the immediate proxy
  # address observed by OpenClaw and replaces this bootstrap-only value.
  apply_base oc "image-registry.openshift-image-registry.svc:5000/ai-email-demo" "$webmail_internal" "127.0.0.1"
  oc -n ai-email-demo rollout restart deployment/mail-server deployment/mail-api deployment/openclaw
  oc apply -f "$repo_dir/deploy/openshift/routes.yaml"
  oc -n ai-email-demo delete networkpolicy openclaw-egress-after --ignore-not-found
  oc apply -f "$repo_dir/deploy/network-policy/before-permissive.yaml"
  oc -n ai-email-demo rollout status deployment/mail-server --timeout=180s
  oc -n ai-email-demo rollout status deployment/webmail --timeout=180s
  oc -n ai-email-demo rollout status deployment/mail-api --timeout=180s
  oc -n ai-email-demo rollout status deployment/openclaw --timeout=180s
  oc -n ai-email-demo rollout status deployment/unauthorized-demo-service --timeout=180s
  openclaw_route=$(oc -n ai-email-demo get route openclaw -o jsonpath='{.spec.host}')
  # A harmless WebSocket upgrade makes OpenClaw record the real immediate
  # OpenShift proxy address. A plain HTTP GET does not reach the Gateway's
  # proxy-attribution path. This remains exact when CRC networking changes and
  # does not depend on a browser already being open.
  curl --insecure --silent --http1.1 --max-time 3 --output /dev/null \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: ZGVtby1wcm94eS1wcm9iZQ==' \
    "https://${openclaw_route}/" || true
  proxy_ip=""
  attempts=0
  while [ -z "$proxy_ip" ] && [ "$attempts" -lt 10 ]; do
    proxy_ip=$(oc -n ai-email-demo logs deployment/openclaw --since=30s 2>/dev/null |
      sed -n \
        -e 's/.*unattributable proxy-shaped traffic from \([^; ]*\).*/\1/p' \
        -e 's/.*closed before connect .* remote=\([^ ]*\) fwd=.*/\1/p' |
      tail -n 1)
    [ -n "$proxy_ip" ] || sleep 1
    attempts=$((attempts + 1))
  done
  case "$proxy_ip" in
    ''|*[!0-9a-fA-F:.]*)
      echo "Unable to learn a valid OpenShift Route proxy address from OpenClaw." >&2
      exit 1
      ;;
  esac
  router_ip=$(oc -n openshift-ingress get pods \
    -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default \
    -o jsonpath='{.items[0].status.podIP}')
  case "$router_ip" in
    ''|*[!0-9a-fA-F:.]*)
      echo "Unable to discover a valid OpenShift router address." >&2
      exit 1
      ;;
  esac
  echo "Configuring the dynamically discovered OpenShift Route proxy chain for OpenClaw."
  oc -n ai-email-demo get configmap openclaw-config -o json |
    jq --arg proxy_ip "$proxy_ip" --arg router_ip "$router_ip" \
      '.data["openclaw.json"] |= (fromjson | .gateway.trustedProxies = [$proxy_ip, $router_ip] | tojson)' |
    oc apply -f -
  oc -n ai-email-demo rollout restart deployment/openclaw
  oc -n ai-email-demo rollout status deployment/openclaw --timeout=180s
  # Deployment availability can precede HAProxy endpoint propagation by a few
  # seconds on single-node CRC. Require a successful Route response, but retry
  # the transient 503 window instead of making reset timing-dependent.
  route_ready=false
  for _ in $(seq 1 30); do
    if curl --insecure --fail --silent --output /dev/null "https://${openclaw_route}/"; then
      route_ready=true
      break
    fi
    sleep 2
  done
  [ "$route_ready" = true ] || {
    echo "OpenClaw Route did not become ready after proxy configuration." >&2
    exit 1
  }
  echo "OpenClaw Route proxy attribution verified."
  "$repo_dir/scripts/setup-external-demo.sh"
  echo "Checking OpenClaw's configured inference connection..."
  oc -n ai-email-demo exec deployment/openclaw -- node openclaw.mjs models list --provider "${INFERENCE_PROVIDER:-ollama}"
  echo "Creating the demo mailbox and normal messages..."
  # OpenShift Local Routes use the CRC ingress CA, which is not normally in the
  # workstation curl trust store. This is a local smoke test, not a production
  # TLS configuration example.
  curl --insecure --fail --silent --show-error -X POST "https://$(oc -n ai-email-demo get route mail-api -o jsonpath='{.spec.host}')/seed"
  if [ "${DEMO_SKIP_CHAT_SMOKE_TEST:-false}" = true ]; then
    echo "Skipping the chatbot smoke test for a clean presentation reset."
  else
    echo "Running an end-to-end chatbot smoke test..."
    oc -n ai-email-demo exec deployment/openclaw -- node openclaw.mjs agent --agent main --message "Summarize today's email" --json
  fi
  echo "OpenShift demo is ready."
  oc -n ai-email-demo get routes
  echo "Show presentation credentials with: make credentials"

  # Retire resource names from the earlier generic ai-agent iteration only
  # after the OpenClaw deployment and smoke test have succeeded.
  oc -n ai-email-demo delete deployment,service,route,serviceaccount,persistentvolumeclaim \
    ai-agent --ignore-not-found
  oc -n ai-email-demo delete persistentvolumeclaim ai-agent-state --ignore-not-found
  oc -n ai-email-demo delete networkpolicy \
    ai-agent-egress-before ai-agent-egress-after --ignore-not-found
  oc -n ai-email-demo delete buildconfig \
    ai-agent-v1 ai-agent-v2 --ignore-not-found
  oc -n ai-email-demo delete imagestream ai-agent --ignore-not-found
  echo "Superseded ai-agent resources retired; OpenClaw is the authoritative workload."
elif [ "$platform" = "kubernetes" ]; then
  [ "$#" -ge 3 ] || usage
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required" >&2; exit 1; }
  registry=${2%/}
  domain=$3
  ingress_class=${4:-nginx}
  kubectl apply -f "$repo_dir/deploy/base/00-namespace.yaml"
  apply_runtime_secrets kubectl
  apply_base kubectl "$registry" "$roundcube_source"
  kubectl -n ai-email-demo rollout restart deployment/mail-server deployment/mail-api deployment/openclaw
  sed \
    -e "s/INGRESS_CLASS/$ingress_class/g" \
    -e "s/WEBMAIL_HOST/webmail.$domain/g" \
    -e "s/MAIL_API_HOST/mail-api.$domain/g" \
    -e "s/AI_AGENT_HOST/openclaw.$domain/g" \
    "$repo_dir/deploy/kubernetes/ingress.yaml" | kubectl apply -f -
  kubectl -n ai-email-demo delete networkpolicy openclaw-egress-after --ignore-not-found
  kubectl apply -f "$repo_dir/deploy/network-policy/before-permissive.yaml"
  kubectl -n ai-email-demo rollout status deployment/mail-server --timeout=180s
  kubectl -n ai-email-demo rollout status deployment/webmail --timeout=180s
  kubectl -n ai-email-demo rollout status deployment/mail-api --timeout=180s
  kubectl -n ai-email-demo rollout status deployment/openclaw --timeout=180s
  kubectl -n ai-email-demo rollout status deployment/unauthorized-demo-service --timeout=180s
  kubectl -n ai-email-demo delete deployment,service,serviceaccount,persistentvolumeclaim \
    ai-agent --ignore-not-found
  kubectl -n ai-email-demo delete persistentvolumeclaim ai-agent-state --ignore-not-found
  kubectl -n ai-email-demo delete networkpolicy \
    ai-agent-egress-before ai-agent-egress-after --ignore-not-found
  echo "Kubernetes demo is ready at webmail.$domain, mail-api.$domain, and openclaw.$domain"
else
  usage
fi
