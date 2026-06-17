#!/bin/bash
# =============================================================================
# setup-submariner-kubeconfig.sh
#
# Purpose : Create a merged kubeconfig for dual-cluster Submariner troubleshooting
# Usage   : bash setup-submariner-kubeconfig.sh
# Prereq  : ~/.submariner-troubleshooting/.envdetails must exist (see README)
# =============================================================================

set -euo pipefail

########################################
# VARIABLES
########################################

WORKDIR="$HOME/submariner-troubleshooting"
ENV_FILE="$WORKDIR/.envdetails"
FINAL_KUBECONFIG="$WORKDIR/submariner-kubeconfig"
TEMP_OCP1_KUBECONFIG="/tmp/OCP1-kubeconfig"
TEMP_OCP2_KUBECONFIG="/tmp/OCP2-kubeconfig"
OCP1_CONTEXT="OCP1-submariner-admin"
OCP2_CONTEXT="OCP2-submariner-admin"

########################################
# LOAD ENV FILE
########################################

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: Environment file not found: $ENV_FILE"
    echo ""
    echo "Create it with the following content:"
    echo "  OCP1_API=<ocp1-api-hostname-or-ip>"
    echo "  OCP1_PASSWORD=<kubeadmin-password>"
    echo "  OCP2_API=<ocp2-api-hostname-or-ip>"
    echo "  OCP2_PASSWORD=<kubeadmin-password>"
    exit 1
fi

source "$ENV_FILE"

########################################
# VALIDATE VARIABLES
########################################

required_vars=(OCP1_API OCP1_PASSWORD OCP2_API OCP2_PASSWORD)

for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Variable '$var' is missing from $ENV_FILE"
        exit 1
    fi
done

########################################
# CLEANUP
########################################

echo "========================================"
echo "Cleaning previous temporary files..."
echo "========================================"

rm -f "$TEMP_OCP1_KUBECONFIG" "$TEMP_OCP2_KUBECONFIG" "$FINAL_KUBECONFIG"
mkdir -p "$WORKDIR"

########################################
# CREATE OCP1 KUBECONFIG
########################################

echo
echo "========================================"
echo "Logging into OCP1 cluster"
echo "API: $OCP1_API"
echo "========================================"

export KUBECONFIG="$TEMP_OCP1_KUBECONFIG"
rm -f "$KUBECONFIG"

oc login \
  "https://${OCP1_API}:6443" \
  -u kubeadmin \
  -p "${OCP1_PASSWORD}" \
  --insecure-skip-tls-verify=true

CURRENT_CONTEXT=$(oc config current-context)
echo "Current Context: $CURRENT_CONTEXT"

if oc config get-contexts -o name | grep -qx "$OCP1_CONTEXT"; then
    oc config delete-context "$OCP1_CONTEXT" >/dev/null 2>&1 || true
fi

oc config rename-context "$CURRENT_CONTEXT" "$OCP1_CONTEXT"

echo
echo "OCP1 Context Created:"
oc config get-contexts

########################################
# CREATE OCP2 KUBECONFIG
########################################

echo
echo "========================================"
echo "Logging into OCP2 cluster"
echo "API: $OCP2_API"
echo "========================================"

export KUBECONFIG="$TEMP_OCP2_KUBECONFIG"
rm -f "$KUBECONFIG"

oc login \
  "https://${OCP2_API}:6443" \
  -u kubeadmin \
  -p "${OCP2_PASSWORD}" \
  --insecure-skip-tls-verify=true

CURRENT_CONTEXT=$(oc config current-context)
echo "Current Context: $CURRENT_CONTEXT"

if oc config get-contexts -o name | grep -qx "$OCP2_CONTEXT"; then
    oc config delete-context "$OCP2_CONTEXT" >/dev/null 2>&1 || true
fi

oc config rename-context "$CURRENT_CONTEXT" "$OCP2_CONTEXT"

echo
echo "OCP2 Context Created:"
oc config get-contexts

########################################
# MERGE BOTH KUBECONFIGS
########################################

echo
echo "========================================"
echo "Merging into dedicated Submariner kubeconfig"
echo "========================================"

KUBECONFIG="$TEMP_OCP1_KUBECONFIG:$TEMP_OCP2_KUBECONFIG" \
kubectl config view \
  --flatten \
  > "$FINAL_KUBECONFIG"

chmod 600 "$FINAL_KUBECONFIG"

########################################
# VALIDATE FINAL FILE
########################################

export KUBECONFIG="$FINAL_KUBECONFIG"

echo
echo "========================================"
echo "Available Contexts in merged kubeconfig"
echo "========================================"
kubectl config get-contexts

########################################
# TEST OCP1
########################################

echo
echo "========================================"
echo "Testing OCP1 Context"
echo "========================================"
oc --context "$OCP1_CONTEXT" get nodes

########################################
# TEST OCP2
########################################

echo
echo "========================================"
echo "Testing OCP2 Context"
echo "========================================"
oc --context "$OCP2_CONTEXT" get nodes

########################################
# FINAL MESSAGE
########################################

echo
echo "========================================"
echo "SUCCESS - Kubeconfig ready"
echo "========================================"
echo
echo "Location : $FINAL_KUBECONFIG"
echo
echo "To activate:"
echo "  export KUBECONFIG=$FINAL_KUBECONFIG"
echo
echo "Quick verify:"
echo "  oc --context $OCP1_CONTEXT get nodes"
echo "  oc --context $OCP2_CONTEXT get nodes"
echo
echo "Run full diagnose:"
echo "  subctl diagnose all \\"
echo "    --kubeconfig $FINAL_KUBECONFIG \\"
echo "    --context $OCP1_CONTEXT"
echo "========================================"
