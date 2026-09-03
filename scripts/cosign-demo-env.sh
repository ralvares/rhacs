#!/usr/bin/env bash
# Source this file in the Dev Spaces terminal. It prepares the public key,
# internal-registry authentication, and the simple v2 presentation tag used
# by the raw Cosign demonstration.

_cosign_demo_quiet=false
[[ ${1:-} == "--quiet" ]] && _cosign_demo_quiet=true

for _cosign_demo_command in oc jq cosign; do
  command -v "$_cosign_demo_command" >/dev/null 2>&1 || {
    echo "$_cosign_demo_command is required" >&2
    return 1 2>/dev/null || exit 1
  }
done

export DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.config/rhacs-ai-demo/registry-auth}
export COSIGN_PUBLIC_KEY=${COSIGN_PUBLIC_KEY:-$HOME/.config/rhacs-ai-demo/cosign.pub}
mkdir -p "$DOCKER_CONFIG" "$(dirname "$COSIGN_PUBLIC_KEY")"

oc registry login \
  --registry=image-registry.openshift-image-registry.svc:5000 \
  --to="$DOCKER_CONFIG/config.json" \
  --insecure=true >/dev/null

oc -n demo-platform get secret cosign-signing-key \
  -o jsonpath='{.data.cosign\.pub}' | base64 -d > "$COSIGN_PUBLIC_KEY"
chmod 0644 "$COSIGN_PUBLIC_KEY"
cp "$COSIGN_PUBLIC_KEY" /tmp/cosign.pub

export IMAGE=${IMAGE:-image-registry.openshift-image-registry.svc:5000/ai-email-demo/openclaw:v2}

if ! oc -n ai-email-demo get istag openclaw:v2 >/dev/null 2>&1; then
  unset IMAGE
  if ! $_cosign_demo_quiet; then
    echo "Cosign registry authentication and public key are ready."
    echo "The openclaw:v2 tag will be exported after its PipelineRun completes."
  fi
  unset _cosign_demo_command _cosign_demo_quiet
  return 0 2>/dev/null || exit 0
fi

if ! $_cosign_demo_quiet; then
  printf 'Cosign demo environment ready\n'
  printf '  IMAGE=%s (Cosign resolves this tag to its signed digest)\n' "$IMAGE"
  printf '  Public key=%s\n' "$COSIGN_PUBLIC_KEY"
  printf '  Registry auth=%s/config.json\n' "$DOCKER_CONFIG"
fi

unset _cosign_demo_command _cosign_demo_quiet
