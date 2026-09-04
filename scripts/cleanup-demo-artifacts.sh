#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Keep the presentation evidence small and intentional: at most one failed
# release run and one successful release run. Everything else is rehearsal
# debris and makes both the Pipelines and RHACS views harder to explain.
namespace=${DEMO_PLATFORM_NAMESPACE:-demo-platform}
workspace_namespace=${DEVSPACES_USER_NAMESPACE:-developer-devspaces}
delete_all=false
pipeline_history_only=false
case "${1:-}" in
  --all) delete_all=true ;;
  --pipeline-history-only) delete_all=true; pipeline_history_only=true ;;
  "") ;;
  *) echo "usage: $0 [--all|--pipeline-history-only]" >&2; exit 2 ;;
esac

command -v oc >/dev/null 2>&1 || {
  echo "oc is required" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "jq is required" >&2
  exit 1
}

delete_old_pipeline_runs() {
  local runs keep_failed keep_success name
  if [ "$delete_all" = true ]; then
    # Wait for the Kubernetes objects to disappear before touching Tekton
    # Results. If Results are deleted first, the watcher can archive the old
    # runs again while their deletion is still in progress.
    oc -n "$namespace" delete pipelineruns --all --ignore-not-found \
      --wait=true --timeout=5m >/dev/null
    oc -n "$namespace" delete taskruns --all --ignore-not-found \
      --wait=true --timeout=5m >/dev/null
    for _ in $(seq 1 60); do
      [ "$(oc -n "$namespace" get pipelineruns -o name 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ] && \
      [ "$(oc -n "$namespace" get taskruns -o name 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ] && break
      sleep 2
    done
    [ "$(oc -n "$namespace" get pipelineruns -o name 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ] || {
      echo "PipelineRuns still exist after the full cleanup timeout." >&2
      exit 1
    }
    [ "$(oc -n "$namespace" get taskruns -o name 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ] || {
      echo "TaskRuns still exist after the full cleanup timeout." >&2
      exit 1
    }
    echo "Removed every old PipelineRun and TaskRun from $namespace."
    return 0
  else
    runs=$(oc -n "$namespace" get pipelineruns \
      -l app.kubernetes.io/name=openclaw-release -o json 2>/dev/null || printf '{"items":[]}')
  fi
  keep_failed=$(jq -r '[.items[] | select(.status.conditions[0].status == "False")]
    | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty' <<<"$runs")
  keep_success=$(jq -r '[.items[] | select(.status.conditions[0].status == "True")]
    | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty' <<<"$runs")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$name" != "$keep_failed" ] && [ "$name" != "$keep_success" ]; then
      oc -n "$namespace" delete pipelinerun "$name" --wait=false >/dev/null
      echo "Removed stale PipelineRun: $name"
    fi
  done < <(jq -r --argjson all "$delete_all" '.items[]
    | select($all or .status.conditions[0].status == "True" or
      .status.conditions[0].status == "False")
    | .metadata.name' <<<"$runs")
}

delete_archived_pipeline_results() {
  local postgres deleted
  [ "$delete_all" = true ] || return 0

  # OpenShift Pipelines keeps completed runs in Tekton Results after their
  # Kubernetes objects are deleted. Those retained records are what the
  # console labels as archived. Scope the reset to this demo namespace only;
  # never disturb Results history owned by another team or namespace.
  [[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || {
    echo "Refusing to clean Tekton Results for invalid namespace: $namespace" >&2
    exit 1
  }
  postgres=$(oc -n openshift-pipelines get pod \
    -l app.kubernetes.io/name=tekton-results-postgres \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$postgres" ]; then
    echo "Tekton Results is not installed; no archived PipelineRuns to remove."
    return 0
  fi

  deleted=$(oc -n openshift-pipelines exec "$postgres" -- sh -lc \
    "PGPASSWORD=\"\$POSTGRESQL_PASSWORD\" psql -U \"\$POSTGRESQL_USER\" -d \"\$POSTGRESQL_DATABASE\" -Atc \"WITH removed AS (DELETE FROM results WHERE parent = '$namespace' RETURNING 1) SELECT count(*) FROM removed;\"")
  echo "Removed ${deleted:-0} archived Tekton Results record(s) for namespace $namespace."
}

delete_failed_builds() {
  local name build_namespace
  if [ "$delete_all" = true ]; then
    for build_namespace in "$namespace" ai-email-demo; do
      oc -n "$build_namespace" delete builds --all --ignore-not-found --wait=false >/dev/null
      # Completed binary builds can leave large terminated pods behind on CRC.
      # Delete only build-owned terminal pods in the two demo namespaces; never
      # touch application pods or RHACS itself.
      oc -n "$build_namespace" delete pod \
        --field-selector=status.phase=Succeeded \
        -l openshift.io/build.name --ignore-not-found --wait=false >/dev/null 2>&1 || true
      oc -n "$build_namespace" delete pod \
        --field-selector=status.phase=Failed \
        -l openshift.io/build.name --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
    echo "Removed all old demo Build objects and their completed pods."
    return 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    oc -n "$namespace" delete build "$name" --wait=false >/dev/null
    echo "Removed failed Build: $name"
  done < <(oc -n "$namespace" get builds -o json 2>/dev/null | jq -r '
    .items[] | select(.status.phase == "Failed" or .status.phase == "Error" or
      .status.phase == "Cancelled") | .metadata.name')
}

delete_failed_workspace() {
  local phase
  phase=$(oc -n "$workspace_namespace" get devworkspace demo-app \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$phase" = Failed ] || { [ "$delete_all" = true ] && [ -n "$phase" ]; }; then
    oc -n "$workspace_namespace" delete devworkspace demo-app --wait=true >/dev/null
    echo "Removed Dev Spaces workspace: demo-app (previous phase: $phase)"
  fi
}

delete_old_pipeline_runs
delete_archived_pipeline_results
if [ "$pipeline_history_only" = true ]; then
  echo "Pipeline presentation history is empty and ready for exactly two staged runs."
  exit 0
fi
delete_failed_builds
if [ "$delete_all" = true ]; then
  "$repo_dir/scripts/prune-crc-demo-images.sh"
fi
delete_failed_workspace

# Diagnostic pods are never presentation evidence.
oc -n "$namespace" delete pod workstation-test --ignore-not-found --wait=false >/dev/null

if [ "$delete_all" = true ]; then
  echo "Demo artifact cleanup complete. Removed all release runs and the existing workspace."
else
  echo "Demo artifact cleanup complete. Kept only the newest failed and successful release evidence."
fi
