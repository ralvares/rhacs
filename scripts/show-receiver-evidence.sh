#!/usr/bin/env bash
set -euo pipefail

namespace=${DEMO_WEBHOOK_NAMESPACE:-demo-webhook}
deployment=${DEMO_WEBHOOK_DEPLOYMENT:-demo-webhook}

for command_name in oc curl jq; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "$command_name is required" >&2
        exit 1
    }
done

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    bold=$'\033[1m'
    red=$'\033[31m'
    cyan=$'\033[36m'
    yellow=$'\033[33m'
    dim=$'\033[2m'
    reset=$'\033[0m'
else
    bold=''
    red=''
    cyan=''
    yellow=''
    dim=''
    reset=''
fi

receiver_host=$(oc -n "$namespace" get route "$deployment" -o jsonpath='{.spec.host}')
events=$(curl -kfsS --connect-timeout 5 --max-time 15 "https://${receiver_host}/requests")
callback=$(jq -c '[.[] | select(.event == "synthetic-callback")] | last // empty' <<<"$events")
environment=$(jq -c '[.[] | select(.event == "synthetic-environment-file")] | last // empty' <<<"$events")

printf '\n%s%sDEMO RECEIVER EVIDENCE%s\n' "$bold" "$red" "$reset"
printf '%sCurrent recorded events from %s/%s%s\n' "$dim" "$namespace" "$deployment" "$reset"

if [ -n "$callback" ] && jq -e . >/dev/null 2>&1 <<<"$callback"; then
    printf '\n%s%s1. CALLBACK RECEIVED%s\n' "$bold" "$cyan" "$reset"
    jq -r --arg bold "$bold" --arg yellow "$yellow" --arg reset "$reset" '
        "  Received:  \(.received_at)",
        "  Source:    \(.source_ip)",
        "  Workload:  \(.workload)",
        "  Session:   \(.session)",
        "  Identity:  \(.identity)",
        "  Bytes:     \(.bytes)",
        "",
        ($bold + $yellow + "  Captured command results" + $reset),
        (.transcript | split("\n")[] | "    " + .)
    ' <<<"$callback"
else
    printf '\n%s%s1. CALLBACK%s\n' "$bold" "$cyan" "$reset"
    printf '  No callback event is present in the receiver state.\n'
fi

if [ -n "$environment" ] && jq -e . >/dev/null 2>&1 <<<"$environment"; then
    printf '\n%s%s2. SYNTHETIC ENVIRONMENT FILE RECEIVED%s\n' "$bold" "$cyan" "$reset"
    jq -r --arg bold "$bold" --arg yellow "$yellow" --arg reset "$reset" '
        "  Received:  \(.received_at)",
        "  Source:    \(.source_ip)",
        "  Artifact:  \(.artifact)",
        "  Bytes:     \(.bytes)",
        "",
        ($bold + $yellow + "  Captured file content" + $reset),
        (.content | split("\n")[] | "    " + .)
    ' <<<"$environment"
else
    printf '\n%s%s2. SYNTHETIC ENVIRONMENT FILE%s\n' "$bold" "$cyan" "$reset"
    printf '  No environment-file event is present in the receiver state.\n'
fi

printf '\n%sOnly synthetic demonstration data is shown.%s\n\n' "$dim" "$reset"
