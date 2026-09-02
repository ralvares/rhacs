#!/usr/bin/env sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir="$repo_dir/.work/cosign"
key_prefix="$work_dir/rhacs-demo"
namespace=ai-email-demo
registry_host=image-registry.openshift-image-registry.svc:5000

command -v oc >/dev/null 2>&1 || { echo "oc is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
"$repo_dir/scripts/generate-signing-key.sh" >/dev/null

digest=$(oc -n "$namespace" get istag openclaw:v2 -o jsonpath='{.image.metadata.name}')
[ -n "$digest" ] || { echo "openclaw:v2 has no image digest; run setup first" >&2; exit 2; }
image="$registry_host/$namespace/openclaw@$digest"

# Cosign runs inside CRC. Its short-lived builder token is valid only for this
# namespace and is never written into a manifest or the repository.
token=$(oc -n "$namespace" create token builder --duration=15m)
auth=$(printf 'serviceaccount:%s' "$token" | base64 | tr -d '\n')
docker_config=$(jq -nc --arg auth "$auth" \
  '{auths:{"image-registry.openshift-image-registry.svc:5000":{auth:$auth}}}')

oc -n "$namespace" create secret generic cosign-registry-auth \
  --from-literal=config.json="$docker_config" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc -n "$namespace" create secret generic cosign-signing-key \
  --from-file=cosign.key="$key_prefix.key" \
  --from-file=cosign.pub="$key_prefix.pub" \
  --from-file=password="$work_dir/password" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null

oc -n "$namespace" delete job cosign-sign-v2 --ignore-not-found >/dev/null
sed "s#IMAGE_DIGEST_REFERENCE#$image#g" "$repo_dir/deploy/rhacs/cosign-sign-job.yaml" | oc apply -f - >/dev/null

if ! oc -n "$namespace" wait --for=condition=complete job/cosign-sign-v2 --timeout=180s; then
  oc -n "$namespace" logs job/cosign-sign-v2 --all-containers=true || true
  exit 1
fi
oc -n "$namespace" logs job/cosign-sign-v2 --all-containers=true

signature_tag="openclaw:sha256-${digest#sha256:}.sig"
oc -n "$namespace" get istag "$signature_tag" >/dev/null

printf 'Signed immutable image: %s\n' "$image"
printf 'Registry signature: %s/%s/%s\n' "$registry_host" "$namespace" "$signature_tag"
printf 'RHACS public key: %s.pub\n' "$key_prefix"
echo "Signature mode: registry-backed Cosign digest tag"
