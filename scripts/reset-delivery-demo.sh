#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

echo "[1/5] Removing every PipelineRun, TaskRun, archived Result, Build, and workspace..."
"$repo_dir/scripts/cleanup-demo-artifacts.sh" --all

echo "[2/5] Removing the webhook before the administrative source reset..."
oc delete -f "$repo_dir/deploy/pipelines/30-trigger.yaml" \
  --ignore-not-found --wait=true >/dev/null 2>&1 || true

echo "[3/5] Recreating Gitea with both candidate records and recreating Dev Spaces..."
DEMO_REBUILD_WORKSTATION=false DEMO_RECREATE_GITEA_REPOSITORY=true \
  "$repo_dir/scripts/setup-pipelines.sh"

echo "[4/5] Staging rejected v1 and approved-but-held v2..."
"$repo_dir/scripts/stage-affected-pipeline.sh"
"$repo_dir/scripts/stage-approved-pipeline.sh"

echo "[5/5] Verifying the visible delivery state..."
runs=$(oc -n demo-platform get pipelineruns \
  -l app.kubernetes.io/name=openclaw-release -o json)
[ "$(jq '.items | length' <<<"$runs")" -eq 2 ]
[ "$(jq '[.items[].status.conditions[0].status] | sort | join(",")' <<<"$runs")" = "False,True" ]
gitea_host=$(oc -n demo-platform get route gitea -o jsonpath='{.spec.host}')
[ "$(curl -kfsS -u developer:developer \
  "https://${gitea_host}/api/v1/repos/developer/demo-app/commits?limit=10" | jq 'length')" -eq 1 ]
postgres=$(oc -n openshift-pipelines get pod \
  -l app.kubernetes.io/name=tekton-results-postgres \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$postgres" ]; then
  results=$(oc -n openshift-pipelines exec "$postgres" -- sh -lc \
    "PGPASSWORD=\"\$POSTGRESQL_PASSWORD\" psql -U \"\$POSTGRESQL_USER\" -d \"\$POSTGRESQL_DATABASE\" -Atc \"SELECT count(*) FROM results WHERE parent = 'demo-platform';\"")
  [ "$results" -eq 2 ] || {
    echo "Expected two Tekton Results entries; found $results." >&2
    exit 1
  }
fi
echo "Delivery reset: one signed seed commit, rejected v1, approved v2, no older runs or archives."
