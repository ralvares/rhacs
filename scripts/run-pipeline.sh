#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
revision=$(git -c http.sslVerify=false ls-remote \
  "https://developer:developer@gitea-demo-platform.apps-crc.testing/developer/demo-app.git" \
  refs/heads/main | awk '{print $1}')
[ -n "$revision" ] || {
  echo "demo-app main revision was not found; run make pipelines-setup first" >&2
  exit 1
}
sign_candidate=${DEMO_SIGN_CANDIDATE:-true}
source_version=${DEMO_SOURCE_VERSION:-v2}
promote_candidate=${DEMO_PROMOTE_CANDIDATE:-true}
reuse_existing_image=${DEMO_REUSE_EXISTING_IMAGE:-false}
tag="pipeline-${revision}-${source_version}"
case "$sign_candidate" in true|false) ;; *) echo "DEMO_SIGN_CANDIDATE must be true or false" >&2; exit 2 ;; esac
case "$source_version" in v1|v2) ;; *) echo "DEMO_SOURCE_VERSION must be v1 or v2" >&2; exit 2 ;; esac
case "$promote_candidate" in true|false) ;; *) echo "DEMO_PROMOTE_CANDIDATE must be true or false" >&2; exit 2 ;; esac
case "$reuse_existing_image" in true|false) ;; *) echo "DEMO_REUSE_EXISTING_IMAGE must be true or false" >&2; exit 2 ;; esac

cat <<EOF | oc create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: openclaw-release-manual-
  namespace: demo-platform
  labels: {app.kubernetes.io/name: openclaw-release}
spec:
  pipelineRef: {name: openclaw-release}
  taskRunTemplate: {serviceAccountName: pipeline}
  params:
    - {name: git-url, value: "http://gitea.demo-platform.svc.cluster.local:3000/developer/demo-app.git"}
    - {name: revision, value: "$revision"}
    - {name: image-tag, value: "$tag"}
    - {name: source-version, value: "$source_version"}
    - {name: sign-candidate, value: "$sign_candidate"}
    - {name: promote-candidate, value: "$promote_candidate"}
    - {name: reuse-existing-image, value: "$reuse_existing_image"}
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources: {requests: {storage: 3Gi}}
    - name: rox-api-token-auth
      secret: {secretName: rox-api-token}
EOF
