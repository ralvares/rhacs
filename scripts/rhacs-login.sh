#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rhacs_env="$repo_dir/.rhacs.env"

for command_name in oc curl jq; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "$command_name is required" >&2
        exit 1
    }
done

oc -n stackrox get central stackrox-central-services >/dev/null 2>&1 || {
    echo "RHACS Central is not installed in namespace stackrox" >&2
    exit 1
}

central_host=$(oc -n stackrox get route central -o jsonpath='{.spec.host}')
rox_endpoint="${central_host}:443"

write_env() {
    local api_token=$1
    umask 077
    {
        printf 'ROX_ENDPOINT=%q\n' "$rox_endpoint"
        printf 'ROX_API_TOKEN=%q\n' "$api_token"
        case "$rox_endpoint" in
            *.apps-crc.testing|*.apps-crc.testing:*)
                printf 'ROX_INSECURE_CLIENT_SKIP_TLS_VERIFY=true\n'
                ;;
        esac
    } > "$rhacs_env"
    chmod 600 "$rhacs_env"
}

if [ -f "$rhacs_env" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$rhacs_env"
    set +a
    if [ "${ROX_ENDPOINT:-}" = "$rox_endpoint" ] &&
       [ -n "${ROX_API_TOKEN:-}" ] &&
       curl -kfsS -H "Authorization: Bearer $ROX_API_TOKEN" \
           "https://${ROX_ENDPOINT}/v1/metadata" >/dev/null; then
        case "$rox_endpoint" in
            *.apps-crc.testing|*.apps-crc.testing:*)
                if [ "${ROX_INSECURE_CLIENT_SKIP_TLS_VERIFY:-}" != true ]; then
                    write_env "$ROX_API_TOKEN"
                    echo "Updated CRC TLS settings in $rhacs_env."
                fi
                ;;
        esac
        echo "Existing RHACS credentials are valid: $rhacs_env"
        echo "RHACS Make targets will load them automatically."
        echo "For direct roxctl commands, run: make rhacs-shell"
        exit 0
    fi
    echo "Existing RHACS credentials are missing, stale, or belong to another Central; replacing them."
fi

admin_password=$(oc -n stackrox get secret central-htpasswd \
    -o jsonpath='{.data.password}' | base64 -d)
token_response=$(curl -kfsS -u "admin:${admin_password}" \
    -H 'Content-Type: application/json' \
    -d '{"name":"ai-email-demo-use-cases","role":"Admin"}' \
    "https://${central_host}/v1/apitokens/generate")
api_token=$(jq -r '.token // empty' <<<"$token_response")
[ -n "$api_token" ] || {
    echo "RHACS did not return an API token" >&2
    jq . <<<"$token_response" >&2
    exit 1
}

write_env "$api_token"
echo "Created $rhacs_env with mode 600. It is excluded from source control."
echo "RHACS Make targets will load it automatically."
echo "For direct roxctl commands, run: make rhacs-shell"
