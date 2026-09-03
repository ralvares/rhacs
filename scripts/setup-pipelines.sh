#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cicd_namespace=demo-platform
app_namespace=ai-email-demo
gitea_user=developer
gitea_password=developer
gitea_repository=demo-app

"$repo_dir/scripts/cleanup-demo-artifacts.sh"

for command_name in oc curl jq git rsync ssh-keygen; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "$command_name is required" >&2
    exit 1
  }
done

wait_for_csv() {
  namespace=$1 subscription=$2
  echo "Waiting for $subscription..."
  for _ in $(seq 1 90); do
    csv=$(oc -n "$namespace" get subscription "$subscription" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [ -n "$csv" ] && [ "$(oc -n "$namespace" get csv "$csv" -o jsonpath='{.status.phase}' 2>/dev/null || true)" = Succeeded ]; then
      echo "$subscription is ready: $csv"
      return 0
    fi
    sleep 10
  done
  echo "Timed out waiting for $subscription" >&2
  return 1
}

echo "[1/8] Installing OpenShift Pipelines without changing RHACS..."
oc apply -f "$repo_dir/deploy/pipelines/00-operator.yaml"
wait_for_csv openshift-operators openshift-pipelines-operator-rh
oc wait --for=condition=Ready pod -l app.kubernetes.io/part-of=tekton-pipelines \
  -n openshift-pipelines --timeout=10m >/dev/null 2>&1 || true
plugins=$(oc get console.operator.openshift.io cluster -o json | jq -c '
  (.spec.plugins // []) + ["pipelines-console-plugin"] | unique')
oc patch console.operator.openshift.io cluster --type=merge \
  -p "{\"spec\":{\"plugins\":${plugins}}}" >/dev/null
oc -n openshift-pipelines wait --for=condition=Ready pod \
  -l app=pipelines-console-plugin --timeout=5m >/dev/null 2>&1 || {
    echo "Pipelines console plugin is configured but its pod is not Ready." >&2
    exit 1
  }
oc get console.operator.openshift.io cluster -o json | jq -e \
  '.spec.plugins | index("pipelines-console-plugin")' >/dev/null
echo "OpenShift Pipelines console plugin is enabled."

echo "[2/8] Installing OpenShift Dev Spaces..."
oc apply -f "$repo_dir/deploy/devspaces/00-operator.yaml"
wait_for_csv openshift-devspaces devspaces
for _ in $(seq 1 60); do
  oc get crd checlusters.org.eclipse.che >/dev/null 2>&1 && break
  sleep 5
done
oc apply -f "$repo_dir/deploy/devspaces/10-checluster.yaml"

echo "[3/8] Creating the CI/CD namespace, PVCs, and least-privilege service account..."
oc -n "$app_namespace" delete rolebinding developer-application-view \
  --ignore-not-found >/dev/null
oc apply -f "$repo_dir/deploy/pipelines/01-platform.yaml"
oc -n "$cicd_namespace" create secret generic developer-platform-credentials \
  --from-literal=GITEA_USER="$gitea_user" \
  --from-literal=GITEA_PASSWORD="$gitea_password" \
  --from-literal=PASSWORD="$gitea_password" \
  --dry-run=client -o yaml | oc apply -f -
oc -n "$cicd_namespace" create secret generic gitea-webhook-token \
  --from-literal=token='Bearer demo-webhook-token' \
  --dry-run=client -o yaml | oc apply -f -

echo "[4/8] Building the UBI-based Gitea image in the internal registry..."
oc apply -f "$repo_dir/deploy/pipelines/02-builds.yaml"
if ! oc -n "$cicd_namespace" get istag gitea:latest >/dev/null 2>&1; then
  oc -n "$cicd_namespace" start-build gitea --from-dir="$repo_dir/services/gitea" --follow --wait
else
  echo "Reusing demo-platform/gitea:latest"
fi

echo "Building the UBI-based Dev Spaces workstation image..."
if ! oc -n "$cicd_namespace" get buildconfig demo-workstation >/dev/null 2>&1; then
  oc -n "$cicd_namespace" new-build --name=demo-workstation --binary --strategy=docker >/dev/null
fi
oc -n "$cicd_namespace" patch buildconfig demo-workstation --type=merge \
  -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"services/dev-workstation/Dockerfile"}}}}' >/dev/null
if [ "${DEMO_REBUILD_WORKSTATION:-false}" = true ] || \
   ! oc -n "$cicd_namespace" get istag demo-workstation:latest >/dev/null 2>&1; then
  oc -n "$cicd_namespace" start-build demo-workstation \
    --from-dir="$repo_dir" --follow --wait
else
  echo "Reusing tested demo-platform/demo-workstation:latest"
fi

gitea_host=$(oc -n "$cicd_namespace" get route gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)
[ -n "$gitea_host" ] || gitea_host="gitea-${cicd_namespace}.apps-crc.testing"
gitea_root_url="https://${gitea_host}/"
sed "s#GITEA_ROOT_URL#${gitea_root_url}#g" "$repo_dir/deploy/pipelines/03-gitea.yaml" | oc apply -f -
oc -n "$cicd_namespace" rollout restart deployment/gitea >/dev/null
oc -n "$cicd_namespace" rollout status deployment/gitea --timeout=5m

echo "[5/8] Creating the Gitea repository and loading the presentation source..."
gitea_api="https://${gitea_host}/api/v1"
if [ "${DEMO_RECREATE_GITEA_REPOSITORY:-false}" = true ]; then
  if curl -kfsS -u "$gitea_user:$gitea_password" \
    "$gitea_api/repos/$gitea_user/$gitea_repository" >/dev/null 2>&1; then
    curl -kfsS -u "$gitea_user:$gitea_password" -X DELETE \
      "$gitea_api/repos/$gitea_user/$gitea_repository" >/dev/null
    echo "Deleted the previous Gitea repository and all of its history."
  fi
fi
repository_ready=false
for _ in $(seq 1 30); do
  if curl -kfsS -u "$gitea_user:$gitea_password" \
    "$gitea_api/repos/$gitea_user/$gitea_repository" >/dev/null 2>&1; then
    repository_ready=true
    break
  fi
  if curl -kfsS -u "$gitea_user:$gitea_password" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${gitea_repository}\",\"private\":false,\"default_branch\":\"main\"}" \
    "$gitea_api/user/repos" >/dev/null 2>&1; then
    repository_ready=true
    break
  fi
  sleep 2
done
if [ "$repository_ready" != true ]; then
  echo "Gitea is Ready, but the demo account or repository could not be initialized." >&2
  curl -ksS -u "$gitea_user:$gitea_password" \
    "$gitea_api/repos/$gitea_user/$gitea_repository" >&2 || true
  exit 1
fi

# A reset force-pushes the signed v1 starting commit. Remove every existing
# hook first so that administrative reset cannot start a release run. The
# single presentation webhook is recreated only after the reset push.
existing_hooks=$(curl -kfsS -u "$gitea_user:$gitea_password" \
  "$gitea_api/repos/$gitea_user/$gitea_repository/hooks")
while IFS= read -r old_hook; do
  [ -n "$old_hook" ] || continue
  curl -kfsS -u "$gitea_user:$gitea_password" -X DELETE \
    "$gitea_api/repos/$gitea_user/$gitea_repository/hooks/$old_hook" >/dev/null
done < <(jq -r '.[].id' <<<"$existing_hooks")

ssh_dir="$repo_dir/.work/gitea-ssh"
mkdir -p "$ssh_dir"
if [ ! -s "$ssh_dir/id_ed25519" ]; then
  ssh-keygen -q -t ed25519 -N '' -C 'developer@demo-app' -f "$ssh_dir/id_ed25519"
fi
public_key=$(cat "$ssh_dir/id_ed25519.pub")
existing_keys=$(curl -kfsS -u "$gitea_user:$gitea_password" "$gitea_api/user/keys")
if ! jq -e '.[] | select(.title == "Dev Spaces demo key")' <<<"$existing_keys" >/dev/null; then
  curl -kfsS -u "$gitea_user:$gitea_password" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg title 'Dev Spaces demo key' --arg key "$public_key" '{title:$title,key:$key,read_only:false}')" \
    "$gitea_api/user/keys" >/dev/null
fi

source_dir=$(mktemp -d)
trap 'rm -rf "$source_dir"' EXIT
rsync -a --delete \
  --exclude .git --exclude .work --exclude .env --exclude .rhacs.env \
  --exclude outputs --exclude .pytest_cache --exclude __pycache__ \
  "$repo_dir/" "$source_dir/"
# Every rehearsal seeds both compact release inputs in one signed source
# commit. Setup later stages the v1 rejection and v2 approval from this same
# immutable revision, without requiring a live source edit or build.
if [ ! -d "$source_dir/.git" ]; then
  git -C "$source_dir" init -b main
fi
git -C "$source_dir" config user.name "Developer"
git -C "$source_dir" config user.email "developer@demo.test"
git -C "$source_dir" config gpg.format ssh
git -C "$source_dir" config user.signingkey "$ssh_dir/id_ed25519.pub"
git -C "$source_dir" config commit.gpgsign true
git -C "$source_dir" add .
git -C "$source_dir" commit -S -m "Start with affected OpenClaw dependency" >/dev/null
git -C "$source_dir" remote remove origin >/dev/null 2>&1 || true
git -C "$source_dir" remote add origin "https://${gitea_user}:${gitea_password}@${gitea_host}/${gitea_user}/${gitea_repository}.git"
git -C "$source_dir" -c http.sslVerify=false push --force --set-upstream origin main >/dev/null
rm -rf "$source_dir"
trap - EXIT

echo "[6/8] Installing Tekton Tasks, Pipeline, and Gitea trigger..."
oc apply -f "$repo_dir/deploy/pipelines/10-tasks.yaml"
for catalog_task in "$repo_dir"/deploy/pipelines/catalog/*.yaml; do
  oc -n "$cicd_namespace" apply -f "$catalog_task"
done
oc apply -f "$repo_dir/deploy/pipelines/20-pipeline.yaml"
oc apply -f "$repo_dir/deploy/pipelines/30-trigger.yaml"
for _ in $(seq 1 60); do
  webhook_host=$(oc -n "$cicd_namespace" get route gitea-webhook -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [ -n "$webhook_host" ] && break
  sleep 2
done

echo "[7/8] Supplying RHACS and signing credentials to the pipeline..."
[ -f "$repo_dir/.rhacs.env" ] || "$repo_dir/scripts/rhacs-login.sh"
set -a
# shellcheck disable=SC1091
source "$repo_dir/.rhacs.env"
set +a
"$repo_dir/scripts/generate-signing-key.sh" >/dev/null
oc -n "$cicd_namespace" create secret generic rhacs-ci \
  --from-literal=endpoint="$ROX_ENDPOINT" \
  --from-literal=token="$ROX_API_TOKEN" \
  --dry-run=client -o yaml | oc apply -f -
oc -n "$cicd_namespace" create secret generic rox-api-token \
  --from-literal=rox_api_token="$ROX_API_TOKEN" \
  --dry-run=client -o yaml | oc apply -f -
oc -n "$cicd_namespace" create secret generic cosign-signing-key \
  --from-file=cosign.key="$repo_dir/.work/cosign/rhacs-demo.key" \
  --from-file=cosign.pub="$repo_dir/.work/cosign/rhacs-demo.pub" \
  --from-file=password="$repo_dir/.work/cosign/password" \
  --dry-run=client -o yaml | oc apply -f -
printf 'developer@demo.test %s\n' "$public_key" > "$ssh_dir/allowed_signers"
oc -n "$cicd_namespace" create secret generic commit-signing-trust \
  --from-file=allowed_signers="$ssh_dir/allowed_signers" \
  --dry-run=client -o yaml | oc apply -f -

webhook_url="http://el-gitea.${cicd_namespace}.svc.cluster.local:8080"
hooks=$(curl -kfsS -u "$gitea_user:$gitea_password" \
  "$gitea_api/repos/$gitea_user/$gitea_repository/hooks")
matching_hook=$(jq -r --arg url "$webhook_url" '.[] | select(.config.url == $url) | .id' <<<"$hooks" | head -n 1)
if [ -z "$matching_hook" ]; then
  while IFS= read -r old_hook; do
    [ -n "$old_hook" ] || continue
    curl -kfsS -u "$gitea_user:$gitea_password" -X DELETE \
      "$gitea_api/repos/$gitea_user/$gitea_repository/hooks/$old_hook" >/dev/null
  done < <(jq -r '.[].id' <<<"$hooks")
  webhook_payload=$(jq -nc --arg url "$webhook_url" '{
    type:"gitea",
    active:true,
    events:["push"],
    "authorization_header":"Bearer demo-webhook-token",
    config:{url:$url,content_type:"json",insecure_ssl:"1"}
  }')
  curl -kfsS -u "$gitea_user:$gitea_password" -H 'Content-Type: application/json' \
    -d "$webhook_payload" \
    "$gitea_api/repos/$gitea_user/$gitea_repository/hooks" >/dev/null
fi

echo "[8/8] Waiting for Dev Spaces and printing browser entry points..."
for _ in $(seq 1 120); do
  devspaces_url=$(oc -n openshift-devspaces get checluster devspaces -o jsonpath='{.status.cheURL}' 2>/dev/null || true)
  [ -n "$devspaces_url" ] && break
  sleep 10
done
[ -n "$devspaces_url" ] || {
  echo "Dev Spaces did not publish its URL before the timeout." >&2
  exit 1
}

developer_namespace=developer-devspaces
if ! oc get namespace "$developer_namespace" >/dev/null 2>&1; then
  oc adm new-project "$developer_namespace" --admin=developer >/dev/null
fi
oc -n "$cicd_namespace" policy add-role-to-group system:image-puller \
  "system:serviceaccounts:${developer_namespace}" >/dev/null
oc -n "$app_namespace" policy add-role-to-group system:image-puller \
  "system:serviceaccounts:${developer_namespace}" >/dev/null
developer_kubeconfig=$(mktemp)
trap 'rm -f "$developer_kubeconfig"' EXIT
oc --kubeconfig "$developer_kubeconfig" login "$(oc whoami --show-server)" \
  --username=developer --password=developer --insecure-skip-tls-verify=true >/dev/null
oc --kubeconfig "$developer_kubeconfig" -n "$developer_namespace" delete secret \
  gitea-git-credentials gitea-ssh-key --ignore-not-found >/dev/null
oc --kubeconfig "$developer_kubeconfig" -n "$developer_namespace" create secret generic gitea-ssh-key \
  --from-file=id_ed25519="$ssh_dir/id_ed25519" \
  --from-file=id_ed25519.pub="$ssh_dir/id_ed25519.pub" \
  --dry-run=client -o yaml | oc --kubeconfig "$developer_kubeconfig" apply -f -
oc --kubeconfig "$developer_kubeconfig" -n "$developer_namespace" label secret gitea-ssh-key \
  app.kubernetes.io/part-of=che.eclipse.org \
  controller.devfile.io/mount-to-devworkspace=true \
  controller.devfile.io/watch-secret=true --overwrite
oc --kubeconfig "$developer_kubeconfig" -n "$developer_namespace" annotate secret gitea-ssh-key \
  controller.devfile.io/mount-as=file \
  controller.devfile.io/mount-path=/etc/gitea-ssh \
  controller.devfile.io/mount-on-start=true --overwrite

# Mount short-lived demo RHACS credentials as environment variables in the
# workspace. The values remain in a Secret and are refreshed every time the
# delivery environment is prepared; they are never committed to the Devfile.
oc --kubeconfig "$developer_kubeconfig" -n "$developer_namespace" create secret generic rhacs-cli-env \
  --from-literal=ROX_ENDPOINT="$ROX_ENDPOINT" \
  --from-literal=ROX_API_TOKEN="$ROX_API_TOKEN" \
  --from-literal=ROX_INSECURE_CLIENT_SKIP_TLS_VERIFY="${ROX_INSECURE_CLIENT_SKIP_TLS_VERIFY:-true}" \
  --dry-run=client -o yaml | oc --kubeconfig "$developer_kubeconfig" apply -f -
oc --kubeconfig "$developer_kubeconfig" -n "$developer_namespace" label secret rhacs-cli-env \
  app.kubernetes.io/part-of=che.eclipse.org \
  controller.devfile.io/mount-to-devworkspace=true \
  controller.devfile.io/watch-secret=true --overwrite
oc --kubeconfig "$developer_kubeconfig" -n "$developer_namespace" annotate secret rhacs-cli-env \
  controller.devfile.io/mount-as=env \
  controller.devfile.io/mount-on-start=true --overwrite
rm -f "$developer_kubeconfig"
trap - EXIT

repository_url="https://${gitea_host}/${gitea_user}/${gitea_repository}.git"
sed -e "s#DEVSPACES_URL#${devspaces_url}#g" \
  -e "s#GITEA_REPOSITORY_URL#${repository_url}#g" \
  "$repo_dir/deploy/devspaces/20-demo-workspace-link.yaml" | oc apply -f -
GITEA_REPOSITORY_URL="http://gitea.${cicd_namespace}.svc.cluster.local:3000/${gitea_user}/${gitea_repository}.git" \
  "$repo_dir/scripts/create-devspaces-workspace.sh"

echo
echo "Developer delivery environment ready."
echo "  OpenShift:  developer / developer"
echo "  Gitea:      https://${gitea_host}   (developer / developer)"
echo "  Dev Spaces: ${devspaces_url:-still starting}"
echo "  Repository: https://${gitea_host}/${gitea_user}/${gitea_repository}"
if [ -n "$devspaces_url" ]; then
echo "  Workspace:  ${devspaces_url}#${repository_url}"
fi
echo "  Pipeline:   OpenShift console > Pipelines > openclaw-release"
echo "  Admin only: use kubeadmin for operators, RHACS administration, and cluster configuration"
