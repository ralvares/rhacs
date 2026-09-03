#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
chrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
profile_dir="$repo_dir/.work/crc-browser-profile"
url=$(oc -n developer-devspaces get devworkspace demo-app -o jsonpath='{.status.mainUrl}')

[ -x "$chrome" ] || {
  echo "Google Chrome was not found at the standard macOS path." >&2
  exit 1
}
[ -n "$url" ] || {
  echo "The demo-app Dev Spaces workspace is not running." >&2
  exit 1
}

spki=$(
  oc -n openshift-ingress get secret router-certs-default -o jsonpath='{.data.tls\.crt}' \
    | base64 -d \
    | openssl x509 -pubkey -noout \
    | openssl pkey -pubin -outform DER \
    | openssl dgst -sha256 -binary \
    | base64 | tr -d '\n'
)

mkdir -p "$profile_dir"
"$chrome" \
  --user-data-dir="$profile_dir" \
  --ignore-certificate-errors-spki-list="$spki" \
  --new-window "$url" >/dev/null 2>&1 &

echo "Opened the running Dev Spaces workspace in an isolated CRC demo profile."
echo "No certificate was installed and the macOS trust store was not changed."
