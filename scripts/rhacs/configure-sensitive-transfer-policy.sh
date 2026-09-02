#!/usr/bin/env bash
# Compatibility entry point retained for existing rehearsal commands.
set -euo pipefail
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
exec "$repo_dir/scripts/rhacs/configure-file-activity-policy.sh" "$@"
