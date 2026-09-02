#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
revision=$(git -C "$repo_dir/.work/gitea-source" rev-parse HEAD)
tag="pipeline-${revision}"

cat <<EOF | oc create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: openclaw-release-manual-
  namespace: ai-email-cicd
  labels: {app.kubernetes.io/name: openclaw-release}
spec:
  pipelineRef: {name: openclaw-release}
  taskRunTemplate: {serviceAccountName: pipeline}
  params:
    - {name: git-url, value: "http://gitea.ai-email-cicd.svc.cluster.local:3000/demo/ai-email-demo-app.git"}
    - {name: revision, value: "$revision"}
    - {name: image-tag, value: "$tag"}
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources: {requests: {storage: 3Gi}}
    - name: evidence
      persistentVolumeClaim: {claimName: pipeline-evidence}
EOF
