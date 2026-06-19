#!/bin/bash

# =============================================================================
# ArgoCD Backup Script (Production Grade)
# Namespace scoped + Parallel + Validation
# =============================================================================

set -euo pipefail

NAMESPACE="openshift-gitops"
PARALLEL=10

TS=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="argocd_backup_${NAMESPACE}_${TS}"

mkdir -p "$BACKUP_DIR"/{applications,applicationsets,appprojects,argocd}

echo "📦 Starting ArgoCD backup..."
echo "Namespace : $NAMESPACE"
echo "Parallel  : $PARALLEL workers"
echo "Backup Dir: $BACKUP_DIR"
echo

# -----------------------------------------------------------------------------
# Function: Clean YAML (remove runtime noise)
# -----------------------------------------------------------------------------
clean_yaml() {
  sed '/status:/,$d'
}

# -----------------------------------------------------------------------------
# Function: Backup resources in parallel
# -----------------------------------------------------------------------------
backup_resource() {
  local resource=$1
  local folder=$2

  echo "🔹 Processing $resource..."

  total=$(oc get "$resource" -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo 0)

  if [[ "$total" -eq 0 ]]; then
    echo "   ⚠️ No resources found"
    return
  fi

  echo "   Found: $total"

  oc get "$resource" -n "$NAMESPACE" -o name | \
  xargs -I {} -P $PARALLEL bash -c '
    name=$(basename {})
    outfile="'"$BACKUP_DIR/$folder"'/${name}.yaml"

    oc get {} -n "'"$NAMESPACE"'" -o yaml | sed "/status:/,\$d" > "$outfile"

    echo "   ✅ Saved: '"$folder"'/$name"
  '

  echo
}

# -----------------------------------------------------------------------------
# Backup Execution
# -----------------------------------------------------------------------------
backup_resource "applications.argoproj.io" "applications"
backup_resource "applicationsets.argoproj.io" "applicationsets"
backup_resource "appprojects.argoproj.io" "appprojects"
backup_resource "argocds.argoproj.io" "argocd"

# -----------------------------------------------------------------------------
# Count Validation
# -----------------------------------------------------------------------------
echo "🔍 Validating backup counts..."

APP_EXPECTED=$(oc get applications.argoproj.io -n $NAMESPACE --no-headers | wc -l)
APP_BACKED=$(ls $BACKUP_DIR/applications | wc -l)

APPSET_EXPECTED=$(oc get applicationsets.argoproj.io -n $NAMESPACE --no-headers | wc -l)
APPSET_BACKED=$(ls $BACKUP_DIR/applicationsets | wc -l)

PROJ_EXPECTED=$(oc get appprojects.argoproj.io -n $NAMESPACE --no-headers | wc -l)
PROJ_BACKED=$(ls $BACKUP_DIR/appprojects | wc -l)

ARGO_EXPECTED=$(oc get argocds.argoproj.io -n $NAMESPACE --no-headers | wc -l)
ARGO_BACKED=$(ls $BACKUP_DIR/argocd | wc -l)

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
echo "====================================================="
echo "📊 Backup Summary"
echo "====================================================="

printf "%-25s %-10s %-10s\n" "Resource" "Expected" "BackedUp"
printf "%-25s %-10s %-10s\n" "Applications"     "$APP_EXPECTED" "$APP_BACKED"
printf "%-25s %-10s %-10s\n" "ApplicationSets"  "$APPSET_EXPECTED" "$APPSET_BACKED"
printf "%-25s %-10s %-10s\n" "AppProjects"      "$PROJ_EXPECTED" "$PROJ_BACKED"
printf "%-25s %-10s %-10s\n" "ArgoCD Instances" "$ARGO_EXPECTED" "$ARGO_BACKED"

echo "====================================================="

# -----------------------------------------------------------------------------
# Integrity Check
# -----------------------------------------------------------------------------
if [[ "$APP_EXPECTED" -ne "$APP_BACKED" ]] || \
   [[ "$APPSET_EXPECTED" -ne "$APPSET_BACKED" ]]; then
  echo "❌ WARNING: Backup count mismatch detected!"
else
  echo "✅ Backup validation successful"
fi

echo
echo "📁 Backup stored at: $BACKUP_DIR"

# -----------------------------------------------------------------------------
# Optional: Backup critical supporting resources
# -----------------------------------------------------------------------------
echo
echo "🔐 Backing up supporting resources (secrets/configmaps)..."

mkdir -p "$BACKUP_DIR/core"

oc get secrets -n $NAMESPACE -o yaml > "$BACKUP_DIR/core/secrets.yaml"
oc get configmaps -n $NAMESPACE -o yaml > "$BACKUP_DIR/core/configmaps.yaml"

echo "✅ Core resources backed up"

# -----------------------------------------------------------------------------
# Optional: Compress
# -----------------------------------------------------------------------------
tar -czf "${BACKUP_DIR}.tar.gz" "$BACKUP_DIR"

echo "📦 Compressed backup: ${BACKUP_DIR}.tar.gz"

echo
echo "🎉 ArgoCD backup completed successfully!"
