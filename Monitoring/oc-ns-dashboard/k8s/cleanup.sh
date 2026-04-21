#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — Full teardown of OpenShift Workload Monitoring Dashboard
#
# Usage:
#   chmod +x cleanup.sh
#   ./cleanup.sh              # interactive — prompts before deleting
#   ./cleanup.sh --force      # skip confirmation prompt
#   ./cleanup.sh --dry-run    # show what would be deleted, no changes made
#
# Requires: oc CLI logged in with cluster-admin or project-admin
# =============================================================================
set -euo pipefail

NS="ocp-ns-dashboard"
DRY_RUN=false
FORCE=false

for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --force)   FORCE=true   ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
deleted() { echo -e "${RED}[DEL]${NC}   $*"; }

oc_delete() {
  local kind="$1" name="$2" ns_arg=""
  [[ -n "${3:-}" ]] && ns_arg="-n $3"

  if $DRY_RUN; then
    warn "[dry-run] would delete: $kind/$name $ns_arg"; return
  fi

  if oc get "$kind" "$name" $ns_arg &>/dev/null 2>&1; then
    oc delete "$kind" "$name" $ns_arg --ignore-not-found=true
    deleted "$kind/$name $ns_arg"
  else
    info "$kind/$name not found — skipping"
  fi
}

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  OpenShift Workload Monitoring Dashboard — Cleanup${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""

$DRY_RUN && warn "DRY-RUN mode — no resources will be deleted" && echo ""

if ! $FORCE && ! $DRY_RUN; then
  echo -e "${RED}WARNING:${NC} This permanently deletes all resources in namespace '${NS}'"
  echo -e "         including Deployment, RBAC, Route, and the Namespace itself."
  echo ""
  read -r -p "Type 'yes' to confirm: " confirm
  [[ "$confirm" != "yes" ]] && echo "Aborted." && exit 0
  echo ""
fi

# Step 1 — Route (stop traffic first)
info "Step 1/7 — Deleting Route"
oc_delete route ocp-ns-dashboard "$NS"

# Step 2 — Service
info "Step 2/7 — Deleting Service"
oc_delete service ocp-ns-dashboard "$NS"

# Step 3 — Deployment (terminates pods)
info "Step 3/7 — Deleting Deployment"
oc_delete deployment ocp-ns-dashboard "$NS"

if ! $DRY_RUN; then
  info "Waiting for pods to terminate…"
  oc wait --for=delete pod -l app=ocp-ns-dashboard \
    -n "$NS" --timeout=60s 2>/dev/null || true
fi

# Step 4 — RBAC ClusterRoleBinding
info "Step 4/7 — Deleting ClusterRoleBinding"
oc_delete clusterrolebinding ocp-ns-dashboard-viewer-binding

# Step 5 — RBAC ClusterRole
info "Step 5/7 — Deleting ClusterRole"
oc_delete clusterrole ocp-ns-dashboard-viewer

# Step 6 — ServiceAccount
info "Step 6/7 — Deleting ServiceAccount"
oc_delete serviceaccount ocp-ns-dashboard-sa "$NS"

# Step 7 — Namespace (last)
info "Step 7/7 — Deleting Namespace '${NS}'"
if ! $DRY_RUN; then
  if oc get namespace "$NS" &>/dev/null 2>&1; then
    oc delete namespace "$NS" --ignore-not-found=true
    info "Waiting for namespace to terminate…"
    oc wait --for=delete namespace "$NS" --timeout=120s 2>/dev/null || {
      warn "Namespace stuck Terminating — force-removing finalizers"
      oc patch namespace "$NS" \
        -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    }
    deleted "Namespace/$NS"
  else
    info "Namespace $NS not found — skipping"
  fi
else
  warn "[dry-run] would delete: Namespace/$NS"
fi

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
if $DRY_RUN; then
  echo -e "${YELLOW}  Dry-run complete — no changes were made${NC}"
else
  echo -e "${GREEN}  Cleanup complete — all resources removed${NC}"
fi
echo -e "${BOLD}══════════════════════════════════════════════════════════${NC}"
echo ""
