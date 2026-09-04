#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
namespace=${SBOM_NAMESPACE:-ai-email-demo}
output_dir="$repo_dir/sboms"
auth_dir=$(mktemp -d /tmp/rhacs-ai-demo-syft.XXXXXX)
trap 'rm -rf "$auth_dir"' EXIT

for command_name in oc jq syft; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "$command_name is required" >&2; exit 1; }
done

registry=$(oc registry info --public 2>/dev/null)
[ -n "$registry" ] || { echo "The OpenShift public registry route is unavailable." >&2; exit 1; }
oc registry login --to="$auth_dir/config.json" >/dev/null
mkdir -p "$output_dir"

# Remove files from the superseded ai-agent image repository. They are
# generated artifacts and must not remain beside the authoritative OpenClaw set.
rm -f \
  "$output_dir/ai-agent-v1.cdx.json" \
  "$output_dir/ai-agent-v2.cdx.json" \
  "$output_dir/ai-agent-latest.cdx.json"

tags_json=$(oc -n "$namespace" get imagestreamtags -o json | jq -c '[
  .items[]
  | select(.metadata.name | test("\\.sig$") | not)
  | select(.metadata.name == "openclaw:v1"
        or .metadata.name == "openclaw:v2"
        or .metadata.name == "openclaw:latest"
        or .metadata.name == "mail-api:latest"
        or .metadata.name == "document-agent:latest"
        or .metadata.name == "demo-sink:latest")
  | {tag:.metadata.name,digest:.image.metadata.name}
] | sort_by(.tag)')

count=$(jq 'length' <<<"$tags_json")
[ "$count" -gt 0 ] || { echo "No built demo ImageStreamTags were found in $namespace." >&2; exit 1; }

index_tmp="$output_dir/index.json.tmp"
jq -n --arg generatedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg namespace "$namespace" --arg registry "$registry" \
  '{schemaVersion:1,generatedAt:$generatedAt,namespace:$namespace,registry:$registry,images:[]}' >"$index_tmp"

while IFS=$'\t' read -r tag digest; do
  repository=${tag%%:*}
  tag_name=${tag#*:}
  safe_tag=${tag_name//[^A-Za-z0-9_.-]/-}
  filename="${repository}-${safe_tag}.cdx.json"
  image="$registry/$namespace/$repository@$digest"
  echo "Generating $filename from $tag ($digest)"
  DOCKER_CONFIG="$auth_dir" SYFT_REGISTRY_INSECURE_SKIP_TLS_VERIFY=true \
    syft scan "registry:$image" --source-name "$namespace/$tag" --source-version "$digest" \
      --quiet --output "cyclonedx-json@1.5=$output_dir/$filename"
  components=$(jq '.components | length' "$output_dir/$filename")
  packages=$(jq '[.components[] | select(.type != "file")] | length' "$output_dir/$filename")
  files=$(jq '[.components[] | select(.type == "file")] | length' "$output_dir/$filename")
  jq --arg tag "$tag" --arg digest "$digest" --arg image "$image" \
    --arg file "$filename" --argjson components "$components" \
    --argjson packages "$packages" --argjson files "$files" \
    '.images += [{tag:$tag,digest:$digest,image:$image,file:$file,components:$components,packages:$packages,files:$files}]' \
    "$index_tmp" >"$index_tmp.next"
  mv "$index_tmp.next" "$index_tmp"
done < <(jq -r '.[] | [.tag,.digest] | @tsv' <<<"$tags_json")

mv "$index_tmp" "$output_dir/index.json"
echo
echo "Syft SBOM set ready: $output_dir"
jq -r '.images[] | "  \(.tag) -> \(.file) (\(.packages) packages, \(.files) files, \(.digest))"' "$output_dir/index.json"
