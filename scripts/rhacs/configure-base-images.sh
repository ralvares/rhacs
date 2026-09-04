#!/usr/bin/env bash
set -euo pipefail

for command_name in curl jq; do
    command -v "$command_name" >/dev/null 2>&1 || { echo "$command_name is required" >&2; exit 1; }
done
: "${ROX_ENDPOINT:?Set ROX_ENDPOINT for RHACS Central}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN to an RHACS API token}"

api="https://${ROX_ENDPOINT}"
auth=(-H "Authorization: Bearer $ROX_API_TOKEN" -H 'Content-Type: application/json')
base_images=(
    'registry.access.redhat.com/ubi9/python-312|latest|mail-api,document-agent,demo-sink|ai-platform'
    'registry.access.redhat.com/ubi9/nodejs-22|latest|openclaw:v1,openclaw:latest|ai-platform'
)

references=$(curl -ksS "${auth[@]}" "$api/v2/baseimages")
for entry in "${base_images[@]}"; do
    IFS='|' read -r repository tag_pattern consumers owner <<<"$entry"
    id=$(jq -r --arg repository "$repository" \
        '.baseImageReferences[]? | select(.baseImageRepoPath == $repository) | .id' \
        <<<"$references" | head -1)
    body=$(jq -n --arg repository "$repository" --arg pattern "$tag_pattern" \
        '{baseImageRepoPath:$repository, baseImageTagPattern:$pattern}')
    if [ -n "$id" ]; then
        current=$(jq -r --arg id "$id" \
            '.baseImageReferences[] | select(.id == $id) | .baseImageTagPattern' \
            <<<"$references")
        if [ "$current" != "$tag_pattern" ]; then
            update=$(jq -n --arg id "$id" --arg pattern "$tag_pattern" \
                '{id:$id, baseImageTagPattern:$pattern}')
            curl -ksS -X PUT "${auth[@]}" -d "$update" "$api/v2/baseimages/$id" >/dev/null
            action=updated
        else
            action=present
        fi
    else
        response=$(curl -ksS -X POST "${auth[@]}" -d "$body" "$api/v2/baseimages")
        error=$(jq -r '.error // .message // empty' <<<"$response")
        [ -z "$error" ] || { echo "Could not register $repository: $error" >&2; exit 1; }
        action=created
    fi
    printf '%-8s %-56s tag=%-8s consumers=%-20s owner=%s\n' \
        "$action" "$repository" "$tag_pattern" "$consumers" "$owner"
done

echo
echo 'RHACS base-image references:'
curl -ksS "${auth[@]}" "$api/v2/baseimages" | jq -r \
    '.baseImageReferences[] | "  " + .baseImageRepoPath + ":" + .baseImageTagPattern'
