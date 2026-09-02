#!/usr/bin/env bash

# Exit on error (except in specific loop conditions handled manually)
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
operator_dir="$script_dir/operator"
service_dir="$script_dir/service"
wait_timeout=${RHACS_WAIT_TIMEOUT:-15m}

# ------------------------------------------------------------------
# CONFIGURATION & FUNCTIONS
# ------------------------------------------------------------------

print_header() {
    echo "----------------------------------------------------"
    echo "$1"
    echo "----------------------------------------------------"
}

get_credentials() {
    print_header "🔐 RHACS ACCESS CREDENTIALS"
    
    # Check if Central is actually running first to avoid ugly errors
    if ! oc get secret central-htpasswd -n stackrox &>/dev/null; then
        echo "❌ Error: 'central-htpasswd' secret not found."
        echo "   Is RHACS installed and running in namespace 'stackrox'?"
        exit 1
    fi

    CENTRAL_URL=$(oc get route central -n stackrox -o jsonpath='{.spec.host}')
    ADMIN_PASSWORD=$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' | base64 -d)

    if [ -n "$CENTRAL_URL" ]; then
        echo "Console URL: https://$CENTRAL_URL"
        echo "Username:    admin"
        echo "Password:    $ADMIN_PASSWORD"
    else
        echo "⚠️  Warning: Could not retrieve Central Route URL."
    fi
    echo ""
}

delete_rhacs() {
    print_header "🗑️  Deleting RHACS Deployment"

    echo "Step 1: Removing Central and SecuredCluster Services..."
    oc delete -k "$service_dir" --ignore-not-found --wait=false

    echo "Step 2: Removing RHACS Operator..."
    oc delete -k "$operator_dir" --ignore-not-found --wait=false

    echo "Step 3: Waiting for RHACS namespaces to terminate..."
    for namespace in stackrox rhacs-operator; do
        if oc get namespace "$namespace" >/dev/null 2>&1; then
            oc wait --for=delete "namespace/$namespace" --timeout="$wait_timeout"
        fi
    done

    echo "CRDs were preserved. Pass --delete-crds only for an intentional full uninstall."
    if [ "${DELETE_CRDS:-false}" = "true" ]; then
        oc delete crd centrals.platform.stackrox.io securedclusters.platform.stackrox.io --ignore-not-found
    fi

    echo ""
    echo "✅ Delete Complete."
}

install_rhacs() {
    print_header "🚀 Starting RHACS Deployment"

    # 1. Install the Operator
    echo "Step 1: Installing RHACS Operator..."
    oc apply -k "$operator_dir"

    # 2. Wait for the CSV
    echo "Waiting for Operator CSV to reach 'Succeeded' phase..."
    deadline=$((SECONDS + ${RHACS_OPERATOR_TIMEOUT_SECONDS:-900}))
    until oc get csv -n rhacs-operator -l operators.coreos.com/rhacs-operator.rhacs-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Succeeded"; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "RHACS Operator did not become ready before the timeout." >&2
            oc get csv,pods -n rhacs-operator >&2 || true
            exit 1
        fi
        printf "."
        sleep 5
    done
    echo ""
    echo "✅ Operator is Succeeded."

    # 3. Ensure CRDs are established
    echo "Ensuring CRDs are established..."
    oc wait --for condition=established --timeout="$wait_timeout" crd/centrals.platform.stackrox.io
    oc wait --for condition=established --timeout="$wait_timeout" crd/securedclusters.platform.stackrox.io

    # 4. Install Services
    echo "Step 2: Deploying Central and SecuredCluster Services..."
    oc apply -k "$service_dir"

    oc wait -n stackrox --for=condition=Available --timeout="$wait_timeout" central/stackrox-central-services

    print_header "📡 Monitoring CRS Automation Job..."

    # 5. Wait for the Job to exist
    echo "Waiting for Job 'create-cluster-crs' to be created..."
    deadline=$((SECONDS + ${RHACS_JOB_TIMEOUT_SECONDS:-900}))
    until oc get job create-cluster-crs -n stackrox &>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "create-cluster-crs Job was not created before the timeout." >&2
            exit 1
        fi
        printf "."
        sleep 2
    done
    echo ""

    # 6. Stream logs with retry logic (Handles ContainerCreating error)
    echo "Job found. Attempting to attach to logs..."
    
    # We use '|| true' to allow the command to fail without exiting the script,
    # catching the failure in the loop logic instead.
    until oc logs -f job/create-cluster-crs -n stackrox 2>/dev/null; do
        echo "⏳ Pod is initializing (ContainerCreating)... retrying in 3s..."
        sleep 3
        
        # Check if job failed permanently to avoid infinite loop
        if oc get job create-cluster-crs -n stackrox -o jsonpath='{.status.failed}' | grep -q 1; then
             echo "❌ Job failed to start."
             oc describe job create-cluster-crs -n stackrox
             exit 1
        fi
    done

    oc wait -n stackrox --for=condition=complete --timeout="$wait_timeout" job/create-cluster-crs
    oc wait -n stackrox --for=condition=Available --timeout="$wait_timeout" securedcluster/stackrox-secured-cluster-services

    # 7. Show credentials immediately after install
    get_credentials
    
    echo "----------------------------------------------------"
    echo "✅ Deployment and Initialization Complete!"
}

# ------------------------------------------------------------------
# MAIN EXECUTION
# ------------------------------------------------------------------

# Default action
ACTION="install"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --delete) ACTION="delete" ;;
        --delete-crds) ACTION="delete"; DELETE_CRDS=true ;;
        --credentials) ACTION="credentials" ;;
        --install) ACTION="install" ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Execute Action
case "$ACTION" in
    install)
        install_rhacs
        ;;
    delete)
        delete_rhacs
        ;;
    credentials)
        get_credentials
        ;;
esac
