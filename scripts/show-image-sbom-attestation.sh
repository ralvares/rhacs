#!/usr/bin/env bash
set -euo pipefail

if [[ -n ${REGISTRY:-} ]]; then
  registry=$REGISTRY
elif [[ -r /var/run/secrets/kubernetes.io/serviceaccount/token ]]; then
  registry=image-registry.openshift-image-registry.svc:5000
else
  registry=$(oc -n openshift-image-registry get route default-route -o jsonpath='{.spec.host}')
fi
pipeline_namespace=${PIPELINE_NAMESPACE:-demo-platform}
output=${OUTPUT:-sboms/openclaw-attached.cdx.json}

for command_name in oc jq cosign; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "$command_name is required" >&2
    exit 1
  }
done

IMAGE=${IMAGE:-$registry/ai-email-demo/openclaw:v2}

auth_dir=$(mktemp -d /tmp/openclaw-cosign-auth.XXXXXX)
work_dir=$(mktemp -d /tmp/openclaw-attestation.XXXXXX)
trap 'rm -rf "$auth_dir" "$work_dir"' EXIT

if [[ -r /var/run/secrets/kubernetes.io/serviceaccount/token ]]; then
  registry_token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
else
  registry_token=$(oc whoami -t)
fi

auth=$(printf 'serviceaccount:%s' "$registry_token" | base64 | tr -d '\n')
printf '{"auths":{"%s":{"auth":"%s"}}}' "$registry" "$auth" > "$auth_dir/config.json"
export DOCKER_CONFIG=$auth_dir

oc -n "$pipeline_namespace" get secret cosign-signing-key \
  -o jsonpath='{.data.cosign\.pub}' | base64 -d > "$work_dir/cosign.pub"

echo "Image release tag"
echo "  $IMAGE"
echo "  Cosign resolves the tag to the signed image digest before verification."
echo
echo "Verifying signed CycloneDX attestation"
if ! cosign verify-attestation \
  --allow-insecure-registry \
  --insecure-ignore-tlog \
  --type cyclonedx \
  --key "$work_dir/cosign.pub" \
  "$IMAGE" > "$work_dir/verified-attestations.jsonl" 2> "$work_dir/verify.log"; then
  cat "$work_dir/verify.log" >&2
  exit 1
fi
echo "  VERIFIED"

jq -rs '
  map(.payload | @base64d | fromjson)
  | map(select(.predicateType == "https://cyclonedx.org/bom"))
  | last
  | .predicate
' "$work_dir/verified-attestations.jsonl" > "$work_dir/sbom.json"

mkdir -p "$(dirname "$output")"
cp "$work_dir/sbom.json" "$output"

echo
echo "Recovered image SBOM"
jq -r '[
  "  Format: " + (.bomFormat // "unknown") + " " + (.specVersion // ""),
  "  Components: " + ((.components | length) | tostring),
  "  OpenClaw: " + ([.components[]? | select(.name == "openclaw") | .version] | unique | join(", ")),
  "  Saved as: '"$output"'"
] | .[]' "$output"

echo
echo "Selected components"
jq -r '[.components[]? | select(.name == "openclaw" or .name == "node" or .name == "python") | "  \(.name)@\(.version) [\(.type)]"] | unique[]' "$output"
