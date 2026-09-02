#!/usr/bin/env sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
summary="$repo_dir/.work/rhacs/presenter-summary.md"

if [ ! -s "$summary" ]; then
  echo "The stage has not been prepared. Run ./scripts/prepare-supply-chain-demo.sh before the event." >&2
  exit 1
fi

cat "$summary"

cat <<'EOF'

Presenter navigation — no build or scan is started:
  1. RHACS > Vulnerability Management > Images: open openclaw:v1 and show openclaw 2026.2.13.
  2. RHACS > Platform Configuration > Policy Management: filter "Demo -" and show the two enabled policies.
  3. Open the v1 policy result: affected component plus missing signature.
  4. Open openclaw:v2: maintained OpenClaw version and signature verified.
  5. Show policy resources: production / ai-email-demo / app=openclaw.

Keep the terminal closed after this card. All heavy work was completed during preparation.
EOF
