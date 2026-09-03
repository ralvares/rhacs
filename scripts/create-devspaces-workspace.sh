#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
namespace=${DEVSPACES_USER_NAMESPACE:-developer-devspaces}
workspace_name=${DEVSPACES_WORKSPACE_NAME:-demo-app}
repository_url=${GITEA_REPOSITORY_URL:?GITEA_REPOSITORY_URL is required}

for command_name in oc jq yq uuidgen; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "$command_name is required to create the Dev Spaces workspace" >&2
    exit 1
  }
done

creator_uid=$(oc get user developer -o jsonpath='{.metadata.uid}')
developer_kubeconfig=$(mktemp)
trap 'rm -f "$developer_kubeconfig"' EXIT
oc --kubeconfig "$developer_kubeconfig" login "$(oc whoami --show-server)" \
  --username=developer --password=developer --insecure-skip-tls-verify=true >/dev/null
oc --kubeconfig "$developer_kubeconfig" -n "$namespace" delete devworkspace "$workspace_name" \
  --ignore-not-found --wait=true >/dev/null

# Use the editor definition installed by this Dev Spaces release. This avoids
# pinning an editor image independently from the operator.
oc -n openshift-devspaces get configmap editors-definitions -o json \
  | jq -r '.data["che-code.yaml"]' \
  | yq -o=json '.' \
  | jq '{
      apiVersion:"workspace.devfile.io/v1alpha2",
      kind:"DevWorkspaceTemplate",
      metadata:{name:"demo-che-code",namespace:$namespace},
      spec:(del(.schemaVersion,.metadata))
    }' --arg namespace "$namespace" \
  | oc --kubeconfig "$developer_kubeconfig" apply -f -

apply_workspace() {
  local workspace_id
  workspace_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
  yq -o=json '.' "$repo_dir/devfile.yaml" \
    | jq '{
      apiVersion:"workspace.devfile.io/v1alpha2",
      kind:"DevWorkspace",
      metadata:{
        name:$name,
        namespace:$namespace,
        labels:{
          "controller.devfile.io/creator":$creator,
          "controller.devfile.io/devworkspace_id":$workspace_id
        },
        annotations:{
          "che.eclipse.org/che-editor":"che-incubator/che-code/latest",
          "che.eclipse.org/devfile-source":"demo-platform/setup"
        }
      },
      spec:{
        routingClass:"che",
        started:true,
        contributions:[{
          name:"editor",
          kubernetes:{name:"demo-che-code",namespace:$namespace}
        }],
        template:(del(.schemaVersion,.metadata) | .projects=[{
          name:"demo-app",
          git:{remotes:{origin:$repository},checkoutFrom:{remote:"origin",revision:"main"}}
        }])
      }
    }' \
      --arg name "$workspace_name" \
      --arg namespace "$namespace" \
      --arg creator "$creator_uid" \
      --arg workspace_id "$workspace_id" \
      --arg repository "$repository_url" \
    | oc --kubeconfig "$developer_kubeconfig" apply -f -
}

echo "Waiting for Dev Spaces workspace $namespace/$workspace_name..."
workspace_ready=false
for attempt in 1 2 3; do
  apply_workspace
  for _ in $(seq 1 180); do
    phase=$(oc -n "$namespace" get devworkspace "$workspace_name" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$phase" = Running ]; then
      workspace_ready=true
      break 2
    fi
    if [ "$phase" = Failed ]; then
      message=$(oc -n "$namespace" get devworkspace "$workspace_name" \
        -o jsonpath='{.status.message}' 2>/dev/null || true)
      echo "Workspace start attempt $attempt failed: $message" >&2
      break
    fi
    sleep 2
  done
  if [ "$attempt" -lt 3 ]; then
    oc --kubeconfig "$developer_kubeconfig" -n "$namespace" delete \
      devworkspace "$workspace_name" --wait=true >/dev/null
    echo "Retrying workspace creation after the transient failure..."
  fi
done
[ "$workspace_ready" = true ] || {
  echo "Dev Spaces workspace did not reach Running after three attempts." >&2
  exit 1
}

workspace_pod=''
for _ in $(seq 1 60); do
  workspace_pod=$(oc -n "$namespace" get pod \
    -l "controller.devfile.io/devworkspace_name=$workspace_name" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$workspace_pod" ] && break
  sleep 2
done
[ -n "$workspace_pod" ] || {
  echo "Dev Spaces workspace pod was not created." >&2
  exit 1
}
oc -n "$namespace" wait --for=condition=Ready "pod/$workspace_pod" --timeout=5m >/dev/null

# These checks are intentionally API-only. Running oc exec during setup would
# create a user-issued-container-command event in RHACS and dirty the demo.
oc -n "$namespace" get secret gitea-ssh-key rhacs-cli-env >/dev/null
oc -n "$namespace" get devworkspacetemplate demo-che-code -o json \
  | jq -e '.spec.commands[] | select(.id == "init-che-code-command")
      | .exec.commandLine == "nohup /checode/entrypoint-volume.sh > /checode/entrypoint-logs.txt 2>&1 &"' \
      >/dev/null || {
        echo "The operator-provided Che Code terminal startup command was changed." >&2
        exit 1
      }

echo "Dev Spaces workspace ready: $namespace/$workspace_name"
