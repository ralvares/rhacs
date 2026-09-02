#!/usr/bin/env sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
command -v oc >/dev/null 2>&1 || { echo "oc is required" >&2; exit 1; }

oc apply -f "$repo_dir/deploy/external-demo/00-namespaces.yaml"
oc policy add-role-to-user system:image-puller \
  system:serviceaccount:demo-webhook:default -n ai-email-demo
oc apply -f "$repo_dir/deploy/external-demo/10-webhook.yaml"
oc -n demo-webhook rollout restart deployment/demo-webhook
oc -n demo-webhook rollout status deployment/demo-webhook --timeout=180s

echo "External demo namespaces are ready."
echo "Send the HTML message with: make email-injection"
echo "Receiver console: https://$(oc -n demo-webhook get route demo-webhook -o jsonpath='{.spec.host}')"
