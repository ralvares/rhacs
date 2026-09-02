#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cicd_namespace=ai-email-cicd
app_namespace=ai-email-demo
gitea_user=demo
gitea_password=demo
gitea_repository=ai-email-demo-app

for command_name in oc curl jq git rsync; do
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

echo "[2/8] Installing OpenShift Dev Spaces..."
oc apply -f "$repo_dir/deploy/devspaces/00-operator.yaml"
wait_for_csv openshift-devspaces devspaces
for _ in $(seq 1 60); do
  oc api-resources | grep -q '^checlusters' && break
  sleep 5
done
oc apply -f "$repo_dir/deploy/devspaces/10-checluster.yaml"

echo "[3/8] Creating the CI/CD namespace, PVCs, and least-privilege service account..."
oc apply -f "$repo_dir/deploy/pipelines/01-platform.yaml"
oc -n "$cicd_namespace" create secret generic developer-platform-credentials \
  --from-literal=GITEA_USER="$gitea_user" \
  --from-literal=GITEA_PASSWORD="$gitea_password" \
  --from-literal=PASSWORD="$gitea_password" \
  --dry-run=client -o yaml | oc apply -f -

echo "[4/8] Building the UBI-based Gitea image in the internal registry..."
oc apply -f "$repo_dir/deploy/pipelines/02-builds.yaml"
if ! oc -n "$cicd_namespace" get istag gitea:latest >/dev/null 2>&1; then
  oc -n "$cicd_namespace" start-build gitea --from-dir="$repo_dir/services/gitea" --follow --wait
else
  echo "Reusing ai-email-cicd/gitea:latest"
fi

gitea_host=$(oc -n "$cicd_namespace" get route gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)
[ -n "$gitea_host" ] || gitea_host="gitea-${cicd_namespace}.apps-crc.testing"
gitea_root_url="https://${gitea_host}/"
sed "s#GITEA_ROOT_URL#${gitea_root_url}#g" "$repo_dir/deploy/pipelines/03-gitea.yaml" | oc apply -f -
oc -n "$cicd_namespace" rollout status deployment/gitea --timeout=5m

echo "[5/8] Creating the Gitea repository and loading the presentation source..."
gitea_api="https://${gitea_host}/api/v1"
curl -kfsS -u "$gitea_user:$gitea_password" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"${gitea_repository}\",\"private\":false,\"default_branch\":\"main\"}" \
  "$gitea_api/user/repos" >/dev/null 2>&1 || true

source_dir="$repo_dir/.work/gitea-source"
mkdir -p "$source_dir"
rsync -a --delete \
  --exclude .git --exclude .work --exclude .env --exclude .rhacs.env \
  --exclude outputs --exclude .pytest_cache --exclude __pycache__ \
  "$repo_dir/" "$source_dir/"
if [ ! -d "$source_dir/.git" ]; then
  git -C "$source_dir" init -b main
fi
git -C "$source_dir" config user.name "Demo Platform"
git -C "$source_dir" config user.email "platform@demo.test"
git -C "$source_dir" add .
git -C "$source_dir" commit -m "Prepare AI workload supply-chain demo" >/dev/null 2>&1 || true
git -C "$source_dir" remote remove origin >/dev/null 2>&1 || true
git -C "$source_dir" remote add origin "https://${gitea_user}:${gitea_password}@${gitea_host}/${gitea_user}/${gitea_repository}.git"
git -C "$source_dir" -c http.sslVerify=false push --force --set-upstream origin main >/dev/null

echo "[6/8] Installing Tekton Tasks, Pipeline, and Gitea trigger..."
oc apply -f "$repo_dir/deploy/pipelines/10-tasks.yaml"
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
oc -n "$cicd_namespace" create secret generic cosign-signing-key \
  --from-file=cosign.key="$repo_dir/.work/cosign/rhacs-demo.key" \
  --from-file=cosign.pub="$repo_dir/.work/cosign/rhacs-demo.pub" \
  --from-file=password="$repo_dir/.work/cosign/password" \
  --dry-run=client -o yaml | oc apply -f -

webhook_url="https://${webhook_host}"
hooks=$(curl -kfsS -u "$gitea_user:$gitea_password" \
  "$gitea_api/repos/$gitea_user/$gitea_repository/hooks")
if ! jq -e --arg url "$webhook_url" '.[] | select(.config.url == $url)' <<<"$hooks" >/dev/null; then
  curl -kfsS -u "$gitea_user:$gitea_password" -H 'Content-Type: application/json' \
    -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"${webhook_url}\",\"content_type\":\"json\",\"insecure_ssl\":\"1\"}}" \
    "$gitea_api/repos/$gitea_user/$gitea_repository/hooks" >/dev/null
fi

echo "[8/8] Waiting for Dev Spaces and printing browser entry points..."
for _ in $(seq 1 120); do
  phase=$(oc -n openshift-devspaces get checluster devspaces -o jsonpath='{.status.chePhase}' 2>/dev/null || true)
  [ "$phase" = Active ] && break
  sleep 10
done
devspaces_url=$(oc -n openshift-devspaces get checluster devspaces -o jsonpath='{.status.cheURL}' 2>/dev/null || true)

echo
echo "Developer delivery environment ready."
echo "  Gitea:      https://${gitea_host}   (demo / demo)"
echo "  Dev Spaces: ${devspaces_url:-still starting}"
echo "  Repository: https://${gitea_host}/${gitea_user}/${gitea_repository}"
if [ -n "$devspaces_url" ]; then
  echo "  Workspace:  ${devspaces_url}#https://${gitea_host}/${gitea_user}/${gitea_repository}.git"
fi
echo "  Pipeline:   OpenShift console > Pipelines > openclaw-release"
