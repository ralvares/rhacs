#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
namespace=${SBOM_NAMESPACE:-ai-email-demo}
output_dir="$repo_dir/sboms"
auth_dir=$(mktemp -d /tmp/rhacs-ai-demo-spdx.XXXXXX)
trap 'rm -rf "$auth_dir"' EXIT

for command_name in oc jq syft; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "$command_name is required" >&2
    exit 1
  }
done

registry=$(oc registry info --public 2>/dev/null)
[ -n "$registry" ] || {
  echo "The OpenShift public registry route is unavailable." >&2
  exit 1
}
oc registry login --to="$auth_dir/config.json" >/dev/null
mkdir -p "$output_dir"

for tag in v1 v2; do
  digest=$(oc -n "$namespace" get "istag/openclaw:$tag" -o jsonpath='{.image.metadata.name}')
  [ -n "$digest" ] || {
    echo "openclaw:$tag has no image digest" >&2
    exit 1
  }

  image="$registry/$namespace/openclaw@$digest"
  output="$output_dir/openclaw-$tag.spdx.json"
  echo "Generating $(basename "$output") from openclaw:$tag ($digest)"
  DOCKER_CONFIG="$auth_dir" SYFT_REGISTRY_INSECURE_SKIP_TLS_VERIFY=true \
    syft scan "registry:$image" \
      --source-name "$namespace/openclaw:$tag" \
      --source-version "$digest" \
      --quiet \
      --output "spdx-json@2.3=$output"

  jq -e '
    .spdxVersion == "SPDX-2.3" and
    .dataLicense == "CC0-1.0" and
    (.packages | type == "array")
  ' "$output" >/dev/null
  printf '  SPDX-2.3 validated: %s packages\n' "$(jq '.packages | length' "$output")"
done

echo "SPDX image SBOMs ready in $output_dir"
