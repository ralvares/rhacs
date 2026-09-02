#!/usr/bin/env sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir="$repo_dir/.work/cosign"
key_prefix="$work_dir/rhacs-demo"

command -v cosign >/dev/null 2>&1 || { echo "cosign is required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }
mkdir -p "$work_dir"
chmod 700 "$work_dir"

if [ ! -f "$key_prefix.key" ]; then
  COSIGN_PASSWORD=$(openssl rand -hex 24)
  export COSIGN_PASSWORD
  printf '%s' "$COSIGN_PASSWORD" > "$work_dir/password"
  chmod 600 "$work_dir/password"
  cosign generate-key-pair --output-key-prefix "$key_prefix"
fi

printf 'Cosign public key: %s.pub\n' "$key_prefix"
printf 'Import that public key into the RHACS signature integration.\n'
