#!/usr/bin/env bash
# ==============================================================================
# Script  : ocp-upgrade-healthcheck.sh
# Version : 6.0
# Author  : Arjun / ocp-sysops-kit
# Desc    : Comprehensive OpenShift Upgrade Pre-flight & Health Check Suite.
#           Functional-execution model — toggle RUN_* flags to control checks.
#           Each check is a self-contained bash function.
#
# What's new in v6.0:
#   [NEW-A] Pending CSR detection & approval guidance       → check_pending_csrs()
#   [NEW-B] Critical Prometheus alert check (pre-upgrade)   → check_critical_alerts()
#   [NEW-C] ETCD member health via etcdctl inside pod       → check_etcd_member_health()
#   [FIX-1] PVC/PV awk escape sequence '\e' bug fixed       → printf used instead
#   [FIX-2] Workload artifacts written to ARTIFACT_DIR      → unhealthy pods, replica
#           mismatches, pod-status grouped report, oc get pods -A -o wide dump
#
# Exit Codes:
#   0 = PASS
#   1 = WARNING
#   2 = FAILED
#   3 = PREREQUISITE ERROR
# ==============================================================================

set -u
set -o pipefail

# ==============================================================================
# TOGGLE CHECKS — set true/false to enable or disable individual checks
# ==============================================================================

RUN_CLUSTER_VERSION=true          # [01] Cluster Version & Upgrade Status
RUN_CLUSTER_OPERATORS=true        # [02] Cluster Operators Health
RUN_OLM_OPERATORS=true            # [03] OLM / CSV Operator Status
RUN_NODE_STATUS=true              # [04] Node Ready Status
RUN_NODE_RESOURCES=true           # [05] Node CPU & Memory Usage
RUN_MCP_STATUS=true               # [06] MCP Status + MC Match/Mismatch + Fix Guide
RUN_CONTROL_PLANE_LABELS=true     # [07] Control Plane Node Labels
RUN_API_ETCD_PODS=true            # [08] API Server & ETCD Pod Health
RUN_ETCD_HEALTH=true              # [09] ETCD Operator Conditions & Prometheus Latency
RUN_ETCD_MEMBER_HEALTH=true       # [10] ETCD Member Health via etcdctl (endpoint health + status table)
RUN_WEBHOOKS=true                 # [11] Admission Webhook Validation
RUN_DEPRECATED_APIS=true          # [12] Deprecated API Usage
RUN_CERTIFICATES=true             # [13] TLS Certificate Expiry (<30 days)
RUN_PENDING_CSRS=true             # [14] Pending CSR Detection & Approval Guidance  [NEW]
RUN_CRITICAL_ALERTS=true          # [15] Critical Prometheus Alerts (pre-upgrade gate) [NEW]
RUN_WORKLOADS=true                # [16] Workload Pod Health + Artifacts
RUN_PDB=true                      # [17] Pod Disruption Budget Analysis
RUN_PVC=true                      # [18] PVC & PV Health  [BUG-1 FIXED]
RUN_DISK_SYSROOT=true             # [19] Node /sysroot Disk Usage (via oc debug)
RUN_EVENTS=true                   # [20] Recent Warning Events
RUN_ROUTES=true                   # [21] Application Route Health (HTTP probe)
RUN_EGRESSIP=true                 # [22] EgressIP Assignment & Duplicate Check

TOTAL_CHECKS=22

# ==============================================================================
# CONFIGURATION
# ==============================================================================
EXCLUDE_NS_REGEX="^(openshift|kube)"
CERT_EXPIRY_DAYS=30
CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=15
CPU_MEM_THRESHOLD=70              # % — flag high node CPU/memory usage
DISK_WARN_THRESHOLD=80            # % — flag high /sysroot disk usage

# Artifact output directory — workload reports are saved here (not on dashboard)
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/ocp-upgrade-artifacts-$(date +%Y%m%d-%H%M%S)}"

# ==============================================================================
# INTERNAL STATE
# ==============================================================================
EXIT_CODE=0
WARN_COUNT=0
FAIL_COUNT=0
WARN_ITEMS=()
FAIL_ITEMS=()
CHECKS_RUN=0
CHECKS_SKIPPED=0

# ==============================================================================
# ANSI COLORS  (auto-disabled when not a terminal)
# ==============================================================================
if [[ -n "${CLICOLOR_FORCE:-}" ]] || [[ -t 1 && $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  C_RESET="\e[0m";    C_BOLD="\e[1m"
  C_CYAN="\e[36m";    C_GREEN="\e[32m";   C_YELLOW="\e[33m"
  C_RED="\e[31m";     C_BLUE="\e[34m";    C_MAGENTA="\e[35m"
  C_WHITE="\e[97m";   C_ORANGE="\e[38;5;208m"
else
  C_RESET=""; C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""
  C_RED="";   C_BLUE=""; C_MAGENTA=""; C_WHITE=""; C_ORANGE=""
fi

# ==============================================================================
# HELPERS
# ==============================================================================
mark_warn() { [[ "$EXIT_CODE" -lt 1 ]] && EXIT_CODE=1; ((WARN_COUNT++)); [[ -n "${1:-}" ]] && WARN_ITEMS+=("$1"); }
mark_fail() { EXIT_CODE=2; ((FAIL_COUNT++)); [[ -n "${1:-}" ]] && FAIL_ITEMS+=("$1"); }

section_header() {
  local idx="$1" title="$2"
  echo
  printf "${C_CYAN}${C_BOLD}%s${C_RESET}\n" "══════════════════════════════════════════════════════════════"
  printf "${C_CYAN}${C_BOLD}  [%s/%s] %s${C_RESET}\n" "$idx" "$TOTAL_CHECKS" "$title"
  printf "${C_CYAN}${C_BOLD}%s${C_RESET}\n" "══════════════════════════════════════════════════════════════"
}

skipped_section() {
  local idx="$1" title="$2"
  printf "${C_MAGENTA}  [%s/%s] ⏭  SKIPPED: %s${C_RESET}\n" "$idx" "$TOTAL_CHECKS" "$title"
  ((CHECKS_SKIPPED++))
}

pass()  { printf "  ${C_GREEN}✅ %s${C_RESET}\n" "$*"; }
warn()  { printf "  ${C_YELLOW}⚠️  %s${C_RESET}\n" "$*"; }
fail()  { printf "  ${C_RED}❌ %s${C_RESET}\n" "$*"; }
info()  { printf "  ${C_WHITE}🔎 %s${C_RESET}\n" "$*"; }
note()  { printf "  ${C_BLUE}ℹ️  %s${C_RESET}\n" "$*"; }
artifact_note() { printf "  ${C_MAGENTA}📄 Artifact: %s${C_RESET}\n" "$*"; }

# Portable math — bc with awk fallback
bc_calc() {
  if command -v bc &>/dev/null; then
    echo "scale=1; $1" | bc
  else
    awk "BEGIN {printf \"%.1f\", $1}"
  fi
}

compare_gt() {
  if command -v bc &>/dev/null; then
    [[ $(echo "$1 > $2" | bc) -eq 1 ]]
  else
    awk -v v="$1" -v t="$2" 'BEGIN{exit !(v>t)}'
  fi
}

convert_to_mib() {
  local value="$1"
  local unit="${value//[0-9.]/}"
  local num="${value%"$unit"}"
  case "$unit" in
    Gi) bc_calc "$num * 1024" ;;
    Mi) echo "$num" ;;
    Ki) bc_calc "$num / 1024" ;;
    *)  echo "0.0" ;;
  esac
}

# Write a line to both stdout and an artifact file
tee_artifact() {
  local file="$1"; shift
  printf "%s\n" "$*" | tee -a "$file"
}

# ==============================================================================
# PREREQUISITES
# ==============================================================================
prereq_check() {
  local missing=0
  for cmd in oc jq openssl base64 curl; do
    if ! command -v "$cmd" &>/dev/null; then
      printf "${C_RED}❌ Missing required command: %s${C_RESET}\n" "$cmd"
      ((missing++))
    fi
  done
  [[ "$missing" -gt 0 ]] && { printf "${C_RED}Install missing tools and re-run.${C_RESET}\n"; exit 3; }
  if ! oc whoami &>/dev/null; then
    printf "${C_RED}❌ Not logged into OpenShift. Run: oc login${C_RESET}\n"; exit 3
  fi

  # Create artifact directory
  mkdir -p "$ARTIFACT_DIR"
  printf "${C_MAGENTA}📁 Artifact directory: %s${C_RESET}\n" "$ARTIFACT_DIR"
}

# ==============================================================================
# REPORT HEADER
# ==============================================================================
print_header() {
  local enabled=0
  for var in RUN_CLUSTER_VERSION RUN_CLUSTER_OPERATORS RUN_OLM_OPERATORS RUN_NODE_STATUS \
             RUN_NODE_RESOURCES RUN_MCP_STATUS RUN_CONTROL_PLANE_LABELS RUN_API_ETCD_PODS \
             RUN_ETCD_HEALTH RUN_ETCD_MEMBER_HEALTH RUN_WEBHOOKS RUN_DEPRECATED_APIS \
             RUN_CERTIFICATES RUN_PENDING_CSRS RUN_CRITICAL_ALERTS RUN_WORKLOADS \
             RUN_PDB RUN_PVC RUN_DISK_SYSROOT RUN_EVENTS RUN_ROUTES RUN_EGRESSIP; do
    [[ "${!var}" == "true" ]] && ((enabled++))
  done

  echo
  printf "${C_CYAN}${C_BOLD}%s${C_RESET}\n" "╔══════════════════════════════════════════════════════════════╗"
  printf "${C_CYAN}${C_BOLD}%s${C_RESET}\n" "║       🚀  OPENSHIFT UPGRADE PRE-FLIGHT HEALTH CHECK          ║"
  printf "${C_CYAN}${C_BOLD}%s${C_RESET}\n" "║                   ocp-sysops-kit v6.0                        ║"
  printf "${C_CYAN}${C_BOLD}%s${C_RESET}\n" "╚══════════════════════════════════════════════════════════════╝"
  echo
  printf "  ${C_WHITE}%-15s${C_RESET} %s\n" "📅 Date"       "$(date)"
  printf "  ${C_WHITE}%-15s${C_RESET} %s\n" "👤 User"       "$(oc whoami)"
  printf "  ${C_WHITE}%-15s${C_RESET} %s\n" "🔗 API Server" "$(oc whoami --show-server)"
  printf "  ${C_WHITE}%-15s${C_RESET} %s / %s enabled\n" "📋 Checks" "$enabled" "$TOTAL_CHECKS"
  printf "  ${C_WHITE}%-15s${C_RESET} %s\n" "📁 Artifacts"  "$ARTIFACT_DIR"
  echo
  printf "${C_RED}  🛑 PRE-CHECK REMINDERS:${C_RESET}\n"
  printf "${C_RED}     ➤ Have you taken an ETCD BACKUP before proceeding?${C_RESET}\n"
  printf "${C_RED}     ➤ Validate upgrade path: https://access.redhat.com/labs/ocpupgradegraph/${C_RESET}\n"
  echo
}

# ==============================================================================
# [01] CLUSTER VERSION
# ==============================================================================
check_cluster_version() {
  section_header "01" "Cluster Version & Upgrade Status"
  ((CHECKS_RUN++))
  oc get clusterversion 2>/dev/null || mark_fail "Unable to query ClusterVersion"

  local cv_json channel available
  cv_json=$(oc get clusterversion version -o json 2>/dev/null)
  if [[ -n "$cv_json" ]]; then
    channel=$(echo "$cv_json" | jq -r '.spec.channel // "N/A"')
    available=$(echo "$cv_json" | jq -r '.status.availableUpdates // [] | length')
    note "Channel: $channel   |   Available updates: $available"
    if [[ "$available" -gt 0 ]]; then
      echo "$cv_json" | jq -r '.status.availableUpdates[] | "    → \(.version) [\(.channels | join(", "))]"'
    fi
  fi
  echo
}

# ==============================================================================
# [02] CLUSTER OPERATORS
# ==============================================================================
check_cluster_operators() {
  section_header "02" "Cluster Operators Health"
  ((CHECKS_RUN++))
  info "Expected state: Available=True, Progressing=False, Degraded=False"
  local co_issues
  co_issues=$(oc get co --no-headers 2>/dev/null | grep -v -E "True[[:space:]]+False[[:space:]]+False" || true)
  if [[ -n "$co_issues" ]]; then
    printf "  ${C_YELLOW}%-45s %-10s %-12s %-10s${C_RESET}\n" "OPERATOR" "AVAILABLE" "PROGRESSING" "DEGRADED"
    printf "  ${C_YELLOW}%s${C_RESET}\n" "────────────────────────────────────────────────────────────────────────────"
    while read -r name avail prog deg rest; do
      printf "  ${C_YELLOW}%-45s %-10s %-12s %-10s${C_RESET}\n" "$name" "$avail" "$prog" "$deg"
    done <<< "$co_issues"
    mark_warn "Cluster Operators not fully healthy"
  else
    pass "All Cluster Operators: Available=True, Progressing=False, Degraded=False"
  fi
  echo
}

# ==============================================================================
# [03] OLM OPERATORS (CSV)
# ==============================================================================
check_olm_operators() {
  section_header "03" "OLM Operators (ClusterServiceVersions)"
  ((CHECKS_RUN++))
  info "Checking CSVs not in Succeeded phase..."
  local csv_issues
  csv_issues=$(oc get csv -A --no-headers 2>/dev/null | grep -v Succeeded || true)
  if [[ -n "$csv_issues" ]]; then
    printf "  ${C_YELLOW}%-40s %-40s %-15s${C_RESET}\n" "NAMESPACE" "CSV NAME" "PHASE"
    printf "  ${C_YELLOW}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────"
    while read -r ns name rest phase; do
      printf "  ${C_YELLOW}%-40s %-40s %-15s${C_RESET}\n" "$ns" "$name" "$phase"
    done <<< "$csv_issues"
    mark_warn "OLM operators not in Succeeded state"
  else
    pass "All OLM CSVs are in Succeeded phase."
  fi
  echo
}

# ==============================================================================
# [04] NODE STATUS
# ==============================================================================
check_node_status() {
  section_header "04" "Node Status"
  ((CHECKS_RUN++))
  printf "  ${C_CYAN}%-50s %-20s %-12s %-15s${C_RESET}\n" "NODE" "ROLES" "STATUS" "VERSION"
  printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────"
  oc get nodes --no-headers 2>/dev/null | while read -r name status roles age version; do
    local color="${C_GREEN}"
    [[ "$status" != "Ready" ]] && color="${C_RED}"
    printf "  ${color}%-50s %-20s %-12s %-15s${C_RESET}\n" "$name" "$roles" "$status" "$version"
  done

  local node_issues
  node_issues=$(oc get nodes --no-headers 2>/dev/null | grep -v " Ready " || true)
  [[ -n "$node_issues" ]] && mark_warn "One or more nodes not in Ready state"
  echo
  [[ -z "$node_issues" ]] && pass "All nodes are Ready."
  echo
}

# ==============================================================================
# [05] NODE CPU & MEMORY USAGE
# ==============================================================================
check_node_resources() {
  section_header "05" "Node CPU & Memory Usage"
  ((CHECKS_RUN++))
  note "Threshold: ${CPU_MEM_THRESHOLD}% for flagging high CPU/Memory"

  if oc adm top nodes --no-headers &>/dev/null 2>&1; then
    printf "  ${C_CYAN}%-50s %-14s %-8s %-14s %-8s %-20s${C_RESET}\n" \
      "NODE" "CPU(cores)" "CPU%" "MEMORY" "MEM%" "NOTES"
    printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────"
    oc adm top nodes --no-headers 2>/dev/null | while read -r node cpu cpu_pct mem mem_pct; do
      local cpu_val="${cpu_pct//%/}" mem_val="${mem_pct//%/}"
      local color="${C_GREEN}" notes=""
      compare_gt "${cpu_val:-0}" "$CPU_MEM_THRESHOLD" && { color="${C_RED}"; notes+="[HIGH CPU] "; }
      compare_gt "${mem_val:-0}" "$CPU_MEM_THRESHOLD" && { color="${C_RED}"; notes+="[HIGH MEM] "; }
      printf "  ${color}%-50s %-14s %-8s %-14s %-8s %-20s${C_RESET}\n" \
        "$node" "$cpu" "$cpu_pct" "$mem" "$mem_pct" "$notes"
    done
  else
    warn "Metrics API unavailable (oc adm top failed). Falling back to oc debug per-node..."
    mark_warn "Metrics API unavailable — node resource check via oc debug"

    printf "  ${C_CYAN}%-42s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-20s${C_RESET}\n" \
      "NODE" "MEM_TOT" "MEM_USED" "MEM_FREE" "MEM_AVAIL" "CPU%USER" "CPU%SYS" "CPU%IDLE" "NOTES"
    printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

    for role_label in "node-role.kubernetes.io/master=" "node-role.kubernetes.io/infra=" "node-role.kubernetes.io/worker="; do
      local role="${role_label%%=*}"; role="${role##*/}"
      local nodes
      nodes=$(oc get nodes -l "$role_label" -o name 2>/dev/null | awk -F'/' '{print $2}')
      [[ -z "$nodes" ]] && continue
      printf "\n  ${C_BLUE}── Role: %s ──${C_RESET}\n" "$role"

      for node in $nodes; do
        local mem_out cpu_out
        mem_out=$(timeout 30s oc debug node/"$node" -- chroot /host free -h 2>/dev/null | \
          grep "Mem:" | awk '{print $2, $3, $4, $7}')
        if [[ -z "$mem_out" ]]; then
          printf "  ${C_RED}%-42s  MEM_ERROR${C_RESET}\n" "$node"; continue
        fi
        read -r mem_total mem_used mem_free mem_avail <<< "$mem_out"

        local mem_total_mib mem_used_mib mem_pct notes="" color="${C_GREEN}"
        mem_total_mib=$(convert_to_mib "$mem_total")
        mem_used_mib=$(convert_to_mib "$mem_used")
        if [[ "$mem_total_mib" != "0.0" ]]; then
          mem_pct=$(bc_calc "($mem_used_mib / $mem_total_mib) * 100")
          compare_gt "${mem_pct:-0}" "$CPU_MEM_THRESHOLD" && { notes+="[HIGH MEM ${mem_pct}%] "; color="${C_RED}"; }
        fi

        cpu_out=$(timeout 30s oc debug node/"$node" -- chroot /host sar -u 1 1 2>/dev/null | \
          grep "Average:" | grep -v "CPU" | awk '{print $3, $5, $8}')
        [[ -z "$cpu_out" ]] && \
          cpu_out=$(timeout 30s oc debug node/"$node" -- chroot /host top -bn1 2>/dev/null | \
            grep '%Cpu' | awk '{print $2, $4, $8}')

        local cpu_user="N/A" cpu_sys="N/A" cpu_idle="N/A"
        if [[ -n "$cpu_out" ]]; then
          read -r cpu_user cpu_sys cpu_idle <<< "$cpu_out"
          local cpu_total
          cpu_total=$(bc_calc "${cpu_user:-0} + ${cpu_sys:-0}")
          compare_gt "${cpu_total:-0}" "$CPU_MEM_THRESHOLD" && { notes+="[HIGH CPU ${cpu_total}%] "; color="${C_RED}"; }
        fi

        printf "  ${color}%-42s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-20s${C_RESET}\n" \
          "$node" "$mem_total" "$mem_used" "$mem_free" "$mem_avail" \
          "$cpu_user" "$cpu_sys" "$cpu_idle" "$notes"
      done
    done
  fi
  echo
}

# ==============================================================================
# [06] MCP STATUS + MC MATCH/MISMATCH + FIX GUIDE
# ==============================================================================
check_mcp_status() {
  section_header "06" "Machine Config Pool (MCP) Status & Node MC Match/Mismatch"
  ((CHECKS_RUN++))

  # 6a: MCP overview
  info "MCP Pool Overview:"
  echo
  oc get mcp 2>/dev/null
  echo

  # 6b: Paused/Degraded check
  info "Checking for Paused or Degraded MCPs..."
  local mcp_issues
  mcp_issues=$(oc get mcp -o json 2>/dev/null | jq -r '
    .items[] |
    select(.spec.paused==true or .status.degradedMachineCount > 0) |
    "MCP \(.metadata.name): Paused=\(.spec.paused), DegradedCount=\(.status.degradedMachineCount)"
  ' || true)
  if [[ -n "$mcp_issues" ]]; then
    while read -r line; do printf "  ${C_RED}⚠️  %s${C_RESET}\n" "$line"; done <<< "$mcp_issues"
    mark_fail "MCP is paused or has degraded machines"
  else
    pass "No paused or degraded MCPs found."
  fi
  echo

  # 6c: maxUnavailable table
  info "MCP Settings Summary:"
  printf "  ${C_CYAN}%-20s %-18s %-12s %-12s %-12s %-12s %-10s${C_RESET}\n" \
    "MCP" "MAX_UNAVAILABLE" "MACHINES" "UPDATED" "READY" "DEGRADED" "PAUSED"
  printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────"
  oc get mcp -o json 2>/dev/null | jq -r '
    .items[] |
    [
      .metadata.name,
      (.spec.maxUnavailable // 1 | tostring),
      (.status.machineCount // 0 | tostring),
      (.status.updatedMachineCount // 0 | tostring),
      (.status.readyMachineCount // 0 | tostring),
      (.status.degradedMachineCount // 0 | tostring),
      (.spec.paused | tostring)
    ] | join("|")
  ' | while IFS='|' read -r mcp max_un total updated ready degraded paused; do
    local color="${C_GREEN}"
    [[ "${degraded:-0}" -gt 0 ]] && color="${C_RED}"
    [[ "$paused" == "true" ]]    && color="${C_YELLOW}"
    printf "  ${color}%-20s %-18s %-12s %-12s %-12s %-12s %-10s${C_RESET}\n" \
      "$mcp" "$max_un" "$total" "$updated" "$ready" "$degraded" "$paused"
  done
  echo

  # 6d: Per-node MC match/mismatch table
  info "Node Machine Config Match Status:"
  printf "  ${C_CYAN}%-50s %-38s %-38s %-12s %-10s${C_RESET}\n" \
    "NODE" "CURRENT MC" "DESIRED MC" "MC STATE" "STATUS"
  printf "  ${C_CYAN}%s${C_RESET}\n" "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
  oc get nodes -o json 2>/dev/null | jq -r '
    .items | sort_by(.metadata.name) | .[] |
    {
      name:    .metadata.name,
      current: (.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] // "N/A"),
      desired: (.metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] // "N/A"),
      state:   (.metadata.annotations["machineconfiguration.openshift.io/state"] // "N/A")
    } |
    "\(.name)|\(.current)|\(.desired)|\(.state)|\(if .current == .desired then "Match" else "Mismatch" end)"
  ' | while IFS='|' read -r node current desired state status; do
    local color="${C_GREEN}"
    [[ "$status" == "Mismatch" ]]                    && color="${C_RED}"
    [[ "$state" != "Done" && "$state" != "N/A" ]] && color="${C_YELLOW}"
    printf "  ${color}%-50s %-38s %-38s %-12s %-10s${C_RESET}\n" \
      "$node" "${current:0:37}" "${desired:0:37}" "$state" "$status"
  done

  # 6e: Mismatch fix guide
  local mismatches
  mismatches=$(oc get nodes -o json 2>/dev/null | jq -r '
    .items[] |
    select(
      (.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] // "") !=
      (.metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] // "")
    ) | .metadata.name
  ')

  if [[ -n "$mismatches" ]]; then
    echo
    warn "MC Mismatch on the following nodes:"
    while read -r node; do
      printf "  ${C_RED}  → %s${C_RESET}\n" "$node"
    done <<< "$mismatches"
    echo
    printf "${C_YELLOW}${C_BOLD}  ── HOW TO DIAGNOSE & FIX ────────────────────────────────────────${C_RESET}\n"
    printf "${C_YELLOW}  Step 1: Check MCO pod logs for errors:${C_RESET}\n"
    printf "${C_WHITE}    oc logs -n openshift-machine-config-operator -l k8s-app=machine-config-daemon --tail=100${C_RESET}\n"
    echo
    printf "${C_YELLOW}  Step 2: Check MCD pod on affected node:${C_RESET}\n"
    printf "${C_WHITE}    NODE=<node-name>${C_RESET}\n"
    printf "${C_WHITE}    oc get pod -n openshift-machine-config-operator -l k8s-app=machine-config-daemon --field-selector spec.nodeName=\$NODE${C_RESET}\n"
    echo
    printf "${C_YELLOW}  Step 3: View MCD log on node:${C_RESET}\n"
    printf "${C_WHITE}    oc logs -n openshift-machine-config-operator -l k8s-app=machine-config-daemon -c machine-config-daemon --field-selector spec.nodeName=\$NODE${C_RESET}\n"
    echo
    printf "${C_YELLOW}  Step 4: Force drain + uncordon:${C_RESET}\n"
    printf "${C_WHITE}    oc adm drain \$NODE --ignore-daemonsets --delete-emptydir-data${C_RESET}\n"
    printf "${C_WHITE}    oc adm uncordon \$NODE${C_RESET}\n"
    echo
    printf "${C_YELLOW}  Step 5: Clear currentConfig annotation to force MCO re-evaluation:${C_RESET}\n"
    printf "${C_WHITE}    oc annotate node \$NODE machineconfiguration.openshift.io/currentConfig- --overwrite${C_RESET}\n"
    echo
    printf "${C_YELLOW}  Step 6: Watch MCP convergence:${C_RESET}\n"
    printf "${C_WHITE}    watch oc get mcp${C_RESET}\n"
    printf "${C_YELLOW}${C_BOLD}  ─────────────────────────────────────────────────────────────────${C_RESET}\n"
    mark_warn "Machine Config Mismatch on one or more nodes"
  else
    echo
    pass "All nodes: currentConfig == desiredConfig (MC Match)"
  fi
  echo
}

# ==============================================================================
# [07] CONTROL PLANE LABELS
# ==============================================================================
check_control_plane_labels() {
  section_header "07" "Control Plane Node Labels"
  ((CHECKS_RUN++))
  local control_nodes label_issues=0
  control_nodes=$(oc get nodes -l node-role.kubernetes.io/master= -o name 2>/dev/null || \
                  oc get nodes -l node-role.kubernetes.io/control-plane= -o name 2>/dev/null)
  for node in $control_nodes; do
    if ! oc get "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null | \
         grep -q 'node-role.kubernetes.io/control-plane'; then
      warn "$node MISSING label 'node-role.kubernetes.io/control-plane'"
      ((label_issues++))
      mark_warn "Control-plane node missing label"
    else
      pass "${node#node/} has 'node-role.kubernetes.io/control-plane' label."
    fi
  done
  [[ "$label_issues" -eq 0 ]] && pass "Control-plane label check passed for all master nodes."
  echo
}

# ==============================================================================
# [08] API SERVER & ETCD PODS
# ==============================================================================
check_api_etcd_pods() {
  section_header "08" "API Server & ETCD Pod Health"
  ((CHECKS_RUN++))
  for ns_label in "openshift-apiserver:API Server" "openshift-etcd:ETCD"; do
    local ns="${ns_label%%:*}" label="${ns_label##*:}"
    info "Checking $label pods in namespace: $ns"
    local bad_pods
    bad_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep -v -E "Running|Completed" || true)
    if [[ -n "$bad_pods" ]]; then
      printf "  ${C_RED}%-60s %-15s %-10s${C_RESET}\n" "POD" "STATUS" "RESTARTS"
      while read -r name ready status restarts age; do
        printf "  ${C_RED}%-60s %-15s %-10s${C_RESET}\n" "$name" "$status" "$restarts"
      done <<< "$bad_pods"
      mark_fail "$label pods not Running"
    else
      pass "All $label pods are Running."
    fi
    echo
  done
}

# ==============================================================================
# [09] ETCD OPERATOR CONDITIONS & PROMETHEUS LATENCY
# ==============================================================================
check_etcd_health() {
  section_header "09" "ETCD Operator Conditions & WAL Fsync Latency"
  ((CHECKS_RUN++))

  local etcd_json
  etcd_json=$(oc get etcd cluster -o json 2>/dev/null || true)
  if [[ -z "$etcd_json" ]]; then
    fail "CRITICAL: Unable to fetch ETCD cluster object"
    mark_fail "Cannot fetch ETCD operator status"
  else
    etcd_cond() {
      echo "$etcd_json" | jq -r --arg T "$1" \
        '.status.conditions[] | select(.type==$T) | .status'
    }

    local members_avail members_deg pods_avail ep_deg node_deg
    members_avail=$(etcd_cond "EtcdMembersAvailable")
    members_deg=$(etcd_cond   "EtcdMembersDegraded")
    pods_avail=$(etcd_cond    "StaticPodsAvailable")
    ep_deg=$(etcd_cond        "EtcdEndpointsDegraded")
    node_deg=$(etcd_cond      "NodeControllerDegraded")

    printf "  ${C_CYAN}%-38s %s${C_RESET}\n" "CONDITION" "STATUS"
    printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────"

    local etcd_fail=false
    for row in \
      "EtcdMembersAvailable:${members_avail}:expect_true" \
      "EtcdMembersDegraded:${members_deg}:expect_false" \
      "StaticPodsAvailable:${pods_avail}:expect_true" \
      "EtcdEndpointsDegraded:${ep_deg}:expect_false" \
      "NodeControllerDegraded:${node_deg}:expect_false"; do
      local cond="${row%%:*}"
      local val="${row#*:}"; val="${val%:*}"
      local expect="${row##*:}"
      local color="${C_GREEN}"
      if { [[ "$expect" == "expect_true"  && "$val" != "True" ]] || \
           [[ "$expect" == "expect_false" && "$val" == "True"  ]]; }; then
        color="${C_RED}"; etcd_fail=true
      fi
      printf "  ${color}%-38s %s${C_RESET}\n" "$cond" "$val"
    done

    echo
    if $etcd_fail; then
      fail "ETCD is NOT healthy — DO NOT UPGRADE"
      mark_fail "ETCD core health conditions failed"
    else
      pass "ETCD core health conditions are good."
    fi

    local progressing
    progressing=$(echo "$etcd_json" | jq -r '
      .status.conditions[] |
      select(.type | endswith("Progressing")) |
      select(.status=="True") | .type')
    if [[ -n "$progressing" ]]; then
      warn "ETCD controllers still progressing:"
      while read -r line; do printf "    ${C_YELLOW}→ %s${C_RESET}\n" "$line"; done <<< "$progressing"
      mark_warn "ETCD controllers progressing"
    fi
  fi
  echo

  # Prometheus latency check
  if oc get ns openshift-monitoring &>/dev/null; then
    info "ETCD WAL Fsync Latency (Prometheus p99). Threshold: 20ms"
    local prom_pod
    prom_pod=$(oc -n openshift-monitoring get pod \
      -l app.kubernetes.io/name=prometheus,prometheus=k8s \
      --field-selector=status.phase=Running \
      -o name 2>/dev/null | head -n1 | cut -d/ -f2)

    if [[ -n "$prom_pod" ]]; then
      local result
      result=$(oc -n openshift-monitoring exec -c prometheus "$prom_pod" -- \
        curl -s -G 'http://localhost:9090/api/v1/query' \
        --data-urlencode \
        'query=histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))' \
        2>/dev/null)

      if [[ -z "$result" ]]; then
        warn "Prometheus query failed — skipping fsync latency check."
        mark_warn "ETCD fsync latency check failed"
      else
        local high_lat
        high_lat=$(echo "$result" | jq -r '
          .data.result[] |
          select(.value[1] | tonumber > 0.02) |
          "Instance \(.metric.instance // "unknown") — Latency: \(.value[1])s (Threshold: 0.020s)"')
        if [[ -n "$high_lat" ]]; then
          while read -r line; do printf "  ${C_RED}⚠️  %s${C_RESET}\n" "$line"; done <<< "$high_lat"
          mark_warn "ETCD fsync latency exceeds 20ms threshold"
        else
          pass "ETCD WAL fsync latency within healthy limits (p99 < 20ms)."
        fi
      fi
    else
      warn "Prometheus pod not found — skipping latency check."
      mark_warn "Prometheus unavailable for ETCD latency check"
    fi
  fi
  echo
}

# ==============================================================================
# [10] ETCD MEMBER HEALTH via etcdctl  [NEW]
# ==============================================================================
check_etcd_member_health() {
  section_header "10" "ETCD Member Health (etcdctl endpoint health & status)"
  ((CHECKS_RUN++))

  # Locate a running etcd pod
  local etcd_pod
  etcd_pod=$(oc get pods -n openshift-etcd \
    -l app=etcd \
    --field-selector="status.phase==Running" \
    -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || true)

  if [[ -z "$etcd_pod" ]]; then
    warn "No running etcd pod found in openshift-etcd namespace."
    mark_warn "ETCD pod not found for etcdctl checks"
    echo
    return
  fi

  note "Using etcd pod: $etcd_pod"
  echo

  # ── 10a: endpoint health ────────────────────────────────────────────────────
  info "ETCD Endpoint Health (--cluster):"
  printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────"
  local health_out health_ok=true
  health_out=$(oc exec -n openshift-etcd -c etcdctl "$etcd_pod" -- \
    sh -c "etcdctl endpoint health --cluster" 2>&1 || true)

  if [[ -z "$health_out" ]]; then
    warn "etcdctl endpoint health returned no output. Check etcdctl container availability."
    mark_warn "ETCD endpoint health check returned empty output"
  else
    while read -r line; do
      if echo "$line" | grep -q "is healthy"; then
        printf "  ${C_GREEN}%s${C_RESET}\n" "$line"
      elif echo "$line" | grep -q "is unhealthy\|failed\|error"; then
        printf "  ${C_RED}%s${C_RESET}\n" "$line"
        health_ok=false
      else
        printf "  ${C_WHITE}%s${C_RESET}\n" "$line"
      fi
    done <<< "$health_out"

    echo
    if $health_ok; then
      pass "All ETCD endpoints report healthy."
    else
      fail "One or more ETCD endpoints are unhealthy."
      mark_fail "ETCD endpoint health check failed"
    fi
  fi
  echo

  # ── 10b: endpoint status table ─────────────────────────────────────────────
  info "ETCD Endpoint Status Table:"
  printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────"
  local status_out
  status_out=$(oc exec -n openshift-etcd -c etcdctl "$etcd_pod" -- \
    sh -c "etcdctl endpoint status -w table" 2>&1 || true)

  if [[ -z "$status_out" ]]; then
    warn "etcdctl endpoint status returned no output."
    mark_warn "ETCD endpoint status check returned empty output"
  else
    # Print the table, highlighting the leader row
    local first=true
    while read -r line; do
      if $first; then
        printf "  ${C_CYAN}%s${C_RESET}\n" "$line"
        first=false
      elif echo "$line" | grep -qi "true"; then
        # Leader row (IS LEADER = true)
        printf "  ${C_GREEN}%s ◀ LEADER${C_RESET}\n" "$line"
      elif echo "$line" | grep -q "^[|+]"; then
        printf "  ${C_CYAN}%s${C_RESET}\n" "$line"
      else
        printf "  ${C_WHITE}%s${C_RESET}\n" "$line"
      fi
    done <<< "$status_out"

    # Detect if any member has alarms
    local alarm_count
    alarm_count=$(echo "$status_out" | grep -v "^[|+]" | grep -v "ENDPOINT" | \
      awk -F'|' '{gsub(/ /,"",$7); if($7!=""&&$7!="ERRORS") print}' | wc -l)
    echo
    if [[ "$alarm_count" -gt 0 ]]; then
      warn "ETCD member(s) may have active alarms — review ERRORS column above."
      mark_warn "ETCD member alarms detected"
    else
      pass "No ETCD member alarms detected in status table."
    fi

    # Check DB size warning (>8GB is a concern)
    local db_sizes
    db_sizes=$(echo "$status_out" | grep -v "^[|+]" | grep -v "ENDPOINT" | \
      awk -F'|' '{gsub(/ /,"",$5); print $5}' | grep -E "^[0-9]")
    while read -r sz; do
      # Strip unit, convert to bytes roughly
      local sz_num="${sz//[^0-9.]/}"
      local sz_unit="${sz//[0-9. ]/}"
      local sz_mb=0
      case "${sz_unit,,}" in
        gb|gib) sz_mb=$(bc_calc "${sz_num:-0} * 1024") ;;
        mb|mib) sz_mb="${sz_num:-0}" ;;
        kb|kib) sz_mb=$(bc_calc "${sz_num:-0} / 1024") ;;
        *)      sz_mb=0 ;;
      esac
      if compare_gt "${sz_mb:-0}" "8192"; then
        warn "ETCD DB size is large (${sz}) — consider compaction & defragmentation before upgrade."
        mark_warn "ETCD DB size exceeds 8GB"
      fi
    done <<< "$db_sizes"
  fi
  echo
}

# ==============================================================================
# [11] ADMISSION WEBHOOKS
# ==============================================================================
check_webhooks() {
  section_header "11" "Admission Webhooks (Upgrade Blockers)"
  ((CHECKS_RUN++))
  info "Checking webhooks for missing services or empty endpoints..."
  local failed=0

  for wh_config in $(oc get validatingwebhookconfigurations,mutatingwebhookconfigurations \
                       -o name 2>/dev/null); do
    local svc_data
    svc_data=$(oc get "$wh_config" -o json 2>/dev/null | \
      jq -r '.webhooks[]?.clientConfig.service |
             select(. != null) | "\(.namespace) \(.name)"' | sort -u)
    [[ -z "$svc_data" ]] && continue

    while read -r ns name; do
      if ! oc get service "$name" -n "$ns" &>/dev/null; then
        fail "Webhook '$wh_config' → MISSING service '$ns/$name'"
        ((failed++))
        mark_fail "Broken admission webhook: missing service $ns/$name"
      else
        local ep_count
        ep_count=$(oc get endpoints "$name" -n "$ns" \
          -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
        if [[ "$ep_count" -eq 0 ]]; then
          warn "Webhook '$wh_config' → service '$ns/$name' has NO ENDPOINTS"
          mark_warn "Webhook service has no ready endpoints: $ns/$name"
        fi
      fi
    done <<< "$svc_data"
  done

  [[ "$failed" -eq 0 ]] && pass "No broken webhook configurations detected."
  echo
}

# ==============================================================================
# [12] DEPRECATED APIS
# ==============================================================================
check_deprecated_apis() {
  section_header "12" "Deprecated API Usage"
  ((CHECKS_RUN++))
  info "Scanning APIRequestCounts for removedInRelease and recent usage..."
  local deprecated
  deprecated=$(oc get apirequestcounts 2>/dev/null | awk '
    NR>1 && $2 != "" && $4 > 0 {printf "%-62s %-18s %-10s\n", $1, $2, $4}')
  if [[ -n "$deprecated" ]]; then
    printf "  ${C_YELLOW}%-62s %-18s %-10s${C_RESET}\n" "API RESOURCE" "REMOVED IN" "REQ (24h)"
    printf "  ${C_YELLOW}%s${C_RESET}\n" "─────────────────────────────────────────────────────────────────────────────────────────────"
    while read -r line; do printf "  ${C_YELLOW}%s${C_RESET}\n" "$line"; done <<< "$deprecated"
    note "Fix: update manifests to current API versions before upgrading."
    mark_warn "Deprecated API usage detected — clients must be updated"
  else
    pass "No deprecated API usage detected."
  fi
  echo
}

# ==============================================================================
# [13] TLS CERTIFICATES
# ==============================================================================
check_certificates() {
  section_header "13" "TLS Certificates Expiring < ${CERT_EXPIRY_DAYS} days"
  ((CHECKS_RUN++))
  info "Scanning all TLS secrets cluster-wide..."
  local cert_warn=0

  oc get secrets -A --field-selector=type=kubernetes.io/tls -o json 2>/dev/null | \
  jq -r '.items[] | select(.data."tls.crt" != null) |
          "\(.metadata.namespace) \(.metadata.name) \(.data."tls.crt")"' | \
  while read -r ns name cert_data; do
    local enddate exp_ts now_ts diff
    enddate=$(printf '%s' "$cert_data" | base64 -d 2>/dev/null | \
              openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [[ -z "$enddate" ]] && continue
    exp_ts=$(date -d "$enddate" +%s 2>/dev/null || \
             date -j -f "%b %d %T %Y %Z" "$enddate" +%s 2>/dev/null)
    now_ts=$(date +%s)
    [[ -z "$exp_ts" ]] && continue
    diff=$(( (exp_ts - now_ts) / 86400 ))
    if [[ "$diff" -le "$CERT_EXPIRY_DAYS" ]]; then
      local color="${C_YELLOW}"
      [[ "$diff" -le 7 ]] && color="${C_RED}"
      printf "  ${color}⚠️  %s/%s — expires in %d day(s) (%s)${C_RESET}\n" \
        "$ns" "$name" "$diff" "$enddate"
      cert_warn=1
    fi
  done

  [[ "$cert_warn" -eq 1 ]] && mark_warn "TLS certificates expiring within ${CERT_EXPIRY_DAYS} days"
  pass "Certificate expiry scan complete."
  echo
}

# ==============================================================================
# [14] PENDING CSRs  [NEW]
# ==============================================================================
check_pending_csrs() {
  section_header "14" "Pending Certificate Signing Requests (CSRs)"
  ((CHECKS_RUN++))
  info "Checking for Pending CSRs that need approval before upgrade..."

  local pending_csrs
  pending_csrs=$(oc get csr --no-headers 2>/dev/null | grep "Pending" || true)

  if [[ -z "$pending_csrs" ]]; then
    pass "No pending CSRs found. All certificates are approved."
  else
    local csr_count
    csr_count=$(echo "$pending_csrs" | wc -l)
    printf "  ${C_YELLOW}%-50s %-20s %-12s %-15s${C_RESET}\n" "CSR NAME" "USERNAME" "AGE" "CONDITION"
    printf "  ${C_YELLOW}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────"
    while read -r name age requestor condition; do
      printf "  ${C_YELLOW}%-50s %-20s %-12s %-15s${C_RESET}\n" "$name" "$requestor" "$age" "$condition"
    done <<< "$pending_csrs"

    echo
    printf "  ${C_YELLOW}⚠️  %d pending CSR(s) found.${C_RESET}\n" "$csr_count"
    echo
    printf "${C_YELLOW}${C_BOLD}  ── CSR APPROVAL GUIDE ───────────────────────────────────────────${C_RESET}\n"
    printf "${C_YELLOW}  Approve all pending CSRs (ONLY after verifying requestor identity):${C_RESET}\n"
    echo
    printf "${C_WHITE}    # Review each CSR before approving:${C_RESET}\n"
    printf "${C_WHITE}    oc get csr${C_RESET}\n"
    printf "${C_WHITE}    oc describe csr <csr-name>${C_RESET}\n"
    echo
    printf "${C_WHITE}    # Approve a specific CSR:${C_RESET}\n"
    printf "${C_WHITE}    oc adm certificate approve <csr-name>${C_RESET}\n"
    echo
    printf "${C_WHITE}    # Approve all pending CSRs at once (use with caution):${C_RESET}\n"
    printf "${C_WHITE}    oc get csr -o name | xargs oc adm certificate approve${C_RESET}\n"
    echo
    printf "${C_YELLOW}  ⚠️  During upgrade, new CSRs appear for bootstrapping nodes.${C_RESET}\n"
    printf "${C_YELLOW}     Monitor with: watch oc get csr${C_RESET}\n"
    printf "${C_YELLOW}${C_BOLD}  ─────────────────────────────────────────────────────────────────${C_RESET}\n"
    mark_warn "Pending CSRs require approval before/during upgrade"
  fi
  echo
}

# ==============================================================================
# [15] CRITICAL PROMETHEUS ALERTS  [NEW]
# ==============================================================================
check_critical_alerts() {
  section_header "15" "Critical & Firing Prometheus Alerts (Pre-upgrade Gate)"
  ((CHECKS_RUN++))
  info "Querying Prometheus for firing alerts. Severity: critical or warning."
  note "Cluster should have zero critical alerts before upgrading."
  echo

  # Find Prometheus pod
  local prom_pod
  prom_pod=$(oc -n openshift-monitoring get pod \
    -l app.kubernetes.io/name=prometheus,prometheus=k8s \
    --field-selector=status.phase=Running \
    -o name 2>/dev/null | head -n1 | cut -d/ -f2)

  if [[ -z "$prom_pod" ]]; then
    warn "Prometheus pod not found in openshift-monitoring — skipping alert check."
    mark_warn "Prometheus unavailable for alert check"
    echo
    return
  fi

  # Query firing alerts
  local alert_json
  alert_json=$(oc -n openshift-monitoring exec -c prometheus "$prom_pod" -- \
    curl -s -G 'http://localhost:9090/api/v1/alerts' 2>/dev/null)

  if [[ -z "$alert_json" ]]; then
    warn "Could not retrieve alerts from Prometheus API."
    mark_warn "Prometheus alert query failed"
    echo
    return
  fi

  # Parse firing alerts by severity
  local critical_alerts warning_alerts
  critical_alerts=$(echo "$alert_json" | jq -r '
    .data.alerts[] |
    select(.state=="firing") |
    select(.labels.severity=="critical") |
    select(.labels.alertname != "Watchdog") |
    "CRITICAL | \(.labels.alertname) | \(.labels.namespace // "cluster") | \(.annotations.summary // "N/A")"
  ' 2>/dev/null || true)

  warning_alerts=$(echo "$alert_json" | jq -r '
    .data.alerts[] |
    select(.state=="firing") |
    select(.labels.severity=="warning") |
    select(.labels.alertname != "Watchdog") |
    "WARNING  | \(.labels.alertname) | \(.labels.namespace // "cluster") | \(.annotations.summary // "N/A")"
  ' 2>/dev/null || true)

  local crit_count warn_count
  crit_count=$(echo "$critical_alerts" | grep -c "CRITICAL" 2>/dev/null || echo 0)
  warn_count=$(echo "$warning_alerts"  | grep -c "WARNING"  2>/dev/null || echo 0)
  # guard empty
  [[ "$crit_count" == "" || "$critical_alerts" == "" ]] && crit_count=0
  [[ "$warn_count"  == "" || "$warning_alerts"  == "" ]] && warn_count=0

  # Print critical alerts
  if [[ "$crit_count" -gt 0 ]]; then
    printf "  ${C_RED}${C_BOLD}CRITICAL ALERTS FIRING: %d${C_RESET}\n" "$crit_count"
    printf "  ${C_RED}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────"
    printf "  ${C_RED}%-10s %-45s %-25s %-50s${C_RESET}\n" "SEVERITY" "ALERTNAME" "NAMESPACE" "SUMMARY"
    printf "  ${C_RED}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────"
    while IFS='|' read -r sev alert ns summary; do
      printf "  ${C_RED}%-10s %-45s %-25s %-50s${C_RESET}\n" \
        "${sev// /}" "${alert// /}" "${ns// /}" "${summary:0:49}"
    done <<< "$critical_alerts"
    echo
    fail "CRITICAL alerts are firing — DO NOT UPGRADE until resolved."
    mark_fail "Critical alerts firing: $crit_count critical alert(s) must be resolved"
  else
    pass "No critical alerts are firing."
  fi

  # Print warning alerts
  echo
  if [[ "$warn_count" -gt 0 ]]; then
    printf "  ${C_YELLOW}WARNING ALERTS FIRING: %d${C_RESET}\n" "$warn_count"
    printf "  ${C_YELLOW}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────"
    printf "  ${C_YELLOW}%-10s %-45s %-25s %-50s${C_RESET}\n" "SEVERITY" "ALERTNAME" "NAMESPACE" "SUMMARY"
    printf "  ${C_YELLOW}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────"
    while IFS='|' read -r sev alert ns summary; do
      printf "  ${C_YELLOW}%-10s %-45s %-25s %-50s${C_RESET}\n" \
        "${sev// /}" "${alert// /}" "${ns// /}" "${summary:0:49}"
    done <<< "$warning_alerts"
    echo
    warn "$warn_count warning alert(s) are firing — review before upgrading."
    mark_warn "Warning alerts firing: $warn_count — review recommended"
  else
    pass "No warning alerts are firing."
  fi
  echo
}

# ==============================================================================
# [16] WORKLOAD HEALTH  (with artifacts)
# ==============================================================================
check_workloads() {
  section_header "16" "Workload Health (Pods, Deployments, StatefulSets)"
  ((CHECKS_RUN++))

  local ART_UNHEALTHY="${ARTIFACT_DIR}/unhealthy-pods.txt"
  local ART_REPLICAS="${ARTIFACT_DIR}/replica-mismatches.txt"
  local ART_POD_STATUS="${ARTIFACT_DIR}/pod-status-grouped.txt"
  local ART_PODS_WIDE="${ARTIFACT_DIR}/oc-get-pods-wide.txt"

  # Initialise artifact files with headers
  {
    printf "# OCP Upgrade Health Check — Unhealthy Pods Report\n"
    printf "# Generated: %s\n" "$(date)"
    printf "# Cluster  : %s\n" "$(oc whoami --show-server 2>/dev/null)"
    printf "%s\n\n" "# ──────────────────────────────────────────────────────────────"
  } > "$ART_UNHEALTHY"

  {
    printf "# OCP Upgrade Health Check — Replica Mismatch Report\n"
    printf "# Generated: %s\n" "$(date)"
    printf "# Cluster  : %s\n" "$(oc whoami --show-server 2>/dev/null)"
    printf "%s\n\n" "# ──────────────────────────────────────────────────────────────"
  } > "$ART_REPLICAS"

  {
    printf "# OCP Upgrade Health Check — Pod Status Grouped Report\n"
    printf "# Generated: %s\n" "$(date)"
    printf "# Cluster  : %s\n" "$(oc whoami --show-server 2>/dev/null)"
    printf "%s\n\n" "# ──────────────────────────────────────────────────────────────"
  } > "$ART_POD_STATUS"

  # ── 16a: Full pod wide dump (reference, not on dashboard) ─────────────────
  info "Writing full pod dump (oc get pods -A -o wide) to artifact..."
  {
    printf "# oc get pods -A -o wide\n"
    printf "# Generated: %s\n\n" "$(date)"
    oc get pods -A -o wide 2>/dev/null
  } > "$ART_PODS_WIDE"
  artifact_note "$ART_PODS_WIDE"
  echo

  # ── 16b: Unhealthy pods (dashboard: top 20 only) ──────────────────────────
  info "Pods not in Running/Succeeded phase (dashboard: top 20):"
  local all_pods_json
  all_pods_json=$(oc get pods -A -o json 2>/dev/null)

  local unhealthy_pods
  unhealthy_pods=$(echo "$all_pods_json" | jq -r '
    .items[] |
    select(
      .status.phase != "Succeeded" and
      (
        .status.phase != "Running" or
        any(.status.containerStatuses[]?; .ready == false)
      )
    ) |
    "\(.metadata.namespace)|\(.metadata.name)|\(.status.phase)|\(
       .status.containerStatuses[0].state.waiting.reason   //
       .status.containerStatuses[0].state.terminated.reason //
       "NotReady"
    )|\(.status.hostIP // "N/A")"
  ')

  if [[ -n "$unhealthy_pods" ]]; then
    # Dashboard (top 20)
    printf "  ${C_YELLOW}%-42s %-42s %-18s %-22s %-16s${C_RESET}\n" \
      "NAMESPACE" "POD NAME" "PHASE" "REASON" "NODE IP"
    printf "  ${C_YELLOW}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    echo "$unhealthy_pods" | head -n 20 | while IFS='|' read -r ns pod phase reason hostip; do
      printf "  ${C_YELLOW}%-42s %-42s %-18s %-22s %-16s${C_RESET}\n" \
        "$ns" "$pod" "$phase" "$reason" "$hostip"
    done

    local total_unhealthy
    total_unhealthy=$(echo "$unhealthy_pods" | wc -l)
    [[ "$total_unhealthy" -gt 20 ]] && \
      note "Showing 20 of $total_unhealthy unhealthy pods — see artifact for full list."

    # Full list to artifact
    {
      printf "%-42s %-42s %-18s %-22s %-16s\n" "NAMESPACE" "POD NAME" "PHASE" "REASON" "NODE IP"
      printf "%s\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
      echo "$unhealthy_pods" | while IFS='|' read -r ns pod phase reason hostip; do
        printf "%-42s %-42s %-18s %-22s %-16s\n" "$ns" "$pod" "$phase" "$reason" "$hostip"
      done
    } >> "$ART_UNHEALTHY"
    artifact_note "$ART_UNHEALTHY  (full list: $total_unhealthy pods)"
    mark_warn "Unhealthy pods detected"
  else
    pass "No unhealthy pods detected."
    printf "  No unhealthy pods at time of check.\n" >> "$ART_UNHEALTHY"
  fi
  echo

  # ── 16c: Replica mismatches ───────────────────────────────────────────────
  info "Deployments/StatefulSets with mismatched replicas:"
  local ds_data ds_warn=0
  ds_data=$(oc get deploy,statefulset -A --no-headers 2>/dev/null)

  {
    printf "%-12s %-42s %-42s %-12s %-12s %-12s\n" \
      "KIND" "NAMESPACE" "NAME" "DESIRED" "READY" "AVAILABLE"
    printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
  } >> "$ART_REPLICAS"

  while read -r ns name ready up_to_date available age; do
    IFS='/' read -r actual desired <<< "$ready"
    if [[ "${actual:-0}" != "${desired:-0}" ]]; then
      printf "  ${C_YELLOW}⚠️  %-40s/%-40s — Ready: %s  Desired: %s${C_RESET}\n" \
        "$ns" "$name" "$actual" "$desired"
      printf "%-12s %-42s %-42s %-12s %-12s %-12s\n" \
        "deploy/sts" "$ns" "$name" "$desired" "$actual" "$available" >> "$ART_REPLICAS"
      ((ds_warn++))
    fi
  done <<< "$ds_data"

  if [[ "$ds_warn" -gt 0 ]]; then
    artifact_note "$ART_REPLICAS  ($ds_warn mismatch(es))"
    mark_warn "Deployments/StatefulSets with replica mismatches: $ds_warn"
  else
    pass "All Deployments/StatefulSets have matching replicas."
    printf "  No replica mismatches found.\n" >> "$ART_REPLICAS"
  fi
  echo

  # ── 16d: Pod status grouped report (artifact only) ────────────────────────
  info "Writing pod status grouped report to artifact..."
  {
    printf "\n## Pod Count by Status (all namespaces)\n"
    printf "%-20s %-12s\n" "STATUS" "COUNT"
    printf "%s\n" "──────────────────────────────────"
    echo "$all_pods_json" | jq -r '
      .items | group_by(.status.phase) |
      .[] | "\(.[0].status.phase) \(length)"
    ' | while read -r phase count; do
      printf "%-20s %-12s\n" "$phase" "$count"
    done

    printf "\n## Pod Count by Namespace (excl. openshift* / kube*)\n"
    printf "%-40s %-10s %-10s %-10s\n" "NAMESPACE" "TOTAL" "HEALTHY" "UNHEALTHY"
    printf "%s\n" "──────────────────────────────────────────────────────────────────────"
  } >> "$ART_POD_STATUS"

  # ── 16e: Namespace pod summary (dashboard) ────────────────────────────────
  info "Pod health by namespace (excl. openshift* / kube*):"
  printf "  ${C_CYAN}%-40s %-10s %-20s %-12s${C_RESET}\n" "NAMESPACE" "TOTAL" "RUNNING/HEALTHY" "UNHEALTHY"
  printf "  ${C_CYAN}%s${C_RESET}\n" "─────────────────────────────────────────────────────────────────────────────────────"
  local pod_warn=0
  while read -r ns; do
    local total healthy not_healthy
    total=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
    healthy=$(oc get pods -n "$ns" -o json 2>/dev/null | jq '[
      .items[] |
      select(
        (.status.phase=="Running" and all(.status.containerStatuses[]?; .ready==true)) or
        (.status.phase=="Succeeded")
      )
    ] | length')
    not_healthy=$(( total - healthy ))
    local color="${C_GREEN}"
    [[ "$not_healthy" -gt 0 ]] && { color="${C_YELLOW}"; pod_warn=1; }
    printf "  ${color}%-40s %-10s %-20s %-12s${C_RESET}\n" "$ns" "$total" "$healthy" "$not_healthy"
    printf "%-40s %-10s %-10s %-10s\n" "$ns" "$total" "$healthy" "$not_healthy" >> "$ART_POD_STATUS"
  done < <(oc get namespace -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
           grep -Ev "$EXCLUDE_NS_REGEX")

  artifact_note "$ART_POD_STATUS"
  [[ "$pod_warn" -eq 1 ]] && mark_warn "Unhealthy application pods detected in one or more namespaces"
  echo
}

# ==============================================================================
# [17] PDB ANALYSIS
# ==============================================================================
check_pdb() {
  section_header "17" "Pod Disruption Budget (PDB) Analysis"
  ((CHECKS_RUN++))
  note "minAvailable  → disruptionsAllowed = currentHealthy - minAvailable"
  note "maxUnavailable → disruptionsAllowed = maxUnavailable - (expectedPods - currentHealthy)"
  echo

  local tmp_json
  tmp_json=$(mktemp)
  oc get pdb -A -o json 2>/dev/null > "$tmp_json"

  local table
  table=$(jq -r '
    .items[] |
    select(.metadata.namespace | test("^openshift") | not) |
    {
      ns:            .metadata.namespace,
      name:          .metadata.name,
      expected:      .status.expectedPods,
      healthy:       .status.currentHealthy,
      minAvailable:  .spec.minAvailable,
      maxUnavailable:.spec.maxUnavailable
    } as $p |
    (
      if $p.minAvailable != null then
        { type: "minAvailable",   calc: ($p.healthy - $p.minAvailable) }
      elif $p.maxUnavailable != null then
        { type: "maxUnavailable", calc: ($p.maxUnavailable - ($p.expected - $p.healthy)) }
      else
        { type: "none", calc: 0 }
      end
    ) as $r |
    ($r.calc | if . < 0 then 0 else . end) as $da |
    ($p.expected | if . == 0 then 0 else (($da / .) * 100 + 0.5 | floor) end) as $pct |
    (if $da == 0 then "RED"
     elif $pct == 100 then "BLUE"
     elif $pct < 30 then "ORANGE"
     else "GREEN" end) as $color |
    "\($color)|\($p.ns)|\($p.name)|\($r.type)|\($p.expected)|\($p.healthy)|\($da)|\($pct)%"
  ' "$tmp_json" 2>/dev/null)

  printf "  ${C_CYAN}%-40s %-35s %-15s %-10s %-10s %-12s %-10s${C_RESET}\n" \
    "NAMESPACE" "PDB NAME" "TYPE" "EXPECTED" "HEALTHY" "DISRUPTIONS" "DISRUPT%"
  printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

  local blocked=0 full_outage=0 safe=0 low_ha=0 total=0
  while IFS='|' read -r color ns name type exp healthy da pct; do
    local c
    case "$color" in
      RED)    c="${C_RED}";    ((blocked++)) ;;
      BLUE)   c="${C_BLUE}";   ((full_outage++)) ;;
      ORANGE) c="${C_ORANGE}"; ((low_ha++)) ;;
      GREEN)  c="${C_GREEN}";  ((safe++)) ;;
      *)      c="${C_WHITE}" ;;
    esac
    ((total++))
    printf "  ${c}%-40s %-35s %-15s %-10s %-10s %-12s %-10s${C_RESET}\n" \
      "$ns" "$name" "$type" "$exp" "$healthy" "$da" "$pct"
  done <<< "$table"

  echo
  [[ "$full_outage" -gt 0 ]] && \
    printf "  ${C_ORANGE}${C_BOLD}⚠️  WARNING: %d PDB(s) allow 100%% disruption — full service outage possible!${C_RESET}\n" \
      "$full_outage"

  echo
  printf "  ${C_BOLD}📊 PDB Summary:${C_RESET}\n"
  printf "  ${C_RED}   Blocked (0 disruptions)     : %d${C_RESET}\n"  "$blocked"
  printf "  ${C_ORANGE}   Low HA (<30%% disruption)   : %d${C_RESET}\n"  "$low_ha"
  printf "  ${C_GREEN}   Safe for maintenance        : %d${C_RESET}\n"  "$safe"
  printf "  ${C_BLUE}   Full outage allowed (100%%) : %d${C_RESET}\n"  "$full_outage"
  printf "  ${C_WHITE}   Total PDBs analyzed         : %d${C_RESET}\n"  "$total"

  [[ "$blocked" -gt 0 ]] && mark_fail "PDB(s) blocking all disruptions — upgrade will stall"
  rm -f "$tmp_json"
  echo
}

# ==============================================================================
# [18] PVC / PV HEALTH  [BUG-1 FIXED — no awk \e escape sequences]
# ==============================================================================
check_pvc() {
  section_header "18" "PV & PVC Health"
  ((CHECKS_RUN++))

  # ── 18a: Non-Bound PVCs ───────────────────────────────────────────────────
  info "Non-Bound PVCs:"
  local pvc_json
  pvc_json=$(oc get pvc -A -o json 2>/dev/null)

  local non_bound
  non_bound=$(echo "$pvc_json" | jq -r '
    .items[] |
    select(.status.phase != "Bound") |
    "\(.metadata.namespace)|\(.metadata.name)|\(.status.phase)|\(.spec.resources.requests.storage // "N/A")|\(.spec.storageClassName // "N/A")"
  ' || true)

  if [[ -n "$non_bound" ]]; then
    printf "  ${C_YELLOW}%-38s %-38s %-14s %-12s %-20s${C_RESET}\n" \
      "NAMESPACE" "PVC NAME" "STATUS" "CAPACITY" "STORAGECLASS"
    printf "  ${C_YELLOW}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    while IFS='|' read -r ns name status cap sc; do
      printf "  ${C_YELLOW}%-38s %-38s %-14s %-12s %-20s${C_RESET}\n" \
        "$ns" "$name" "$status" "$cap" "$sc"
    done <<< "$non_bound"
    mark_warn "Non-Bound PVCs detected"
  else
    pass "All PVCs are Bound."
  fi
  echo

  # ── 18b: Terminating PVCs ────────────────────────────────────────────────
  info "PVCs stuck in Terminating:"
  local terminating
  terminating=$(echo "$pvc_json" | jq -r '
    .items[] |
    select(.metadata.deletionTimestamp != null) |
    "\(.metadata.namespace)|\(.metadata.name)|\(.metadata.deletionTimestamp)"
  ' || true)

  if [[ -n "$terminating" ]]; then
    printf "  ${C_RED}%-38s %-38s %-25s${C_RESET}\n" "NAMESPACE" "PVC NAME" "DELETION TIMESTAMP"
    printf "  ${C_RED}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────"
    while IFS='|' read -r ns name ts; do
      printf "  ${C_RED}%-38s %-38s %-25s${C_RESET}\n" "$ns" "$name" "$ts"
    done <<< "$terminating"
    mark_warn "PVCs stuck in Terminating state"
  else
    pass "No PVCs stuck in Terminating."
  fi
  echo

  # ── 18c: PV status summary ───────────────────────────────────────────────
  info "PV Status Summary:"
  local pv_json
  pv_json=$(oc get pv -o json 2>/dev/null)

  printf "  ${C_CYAN}%-45s %-12s %-12s %-20s %-20s${C_RESET}\n" \
    "PV NAME" "CAPACITY" "STATUS" "CLAIM" "STORAGECLASS"
  printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

  local pv_warn=0
  echo "$pv_json" | jq -r '
    .items[] |
    "\(.metadata.name)|\(.spec.capacity.storage // "N/A")|\(.status.phase)|\(
      if .spec.claimRef then "\(.spec.claimRef.namespace)/\(.spec.claimRef.name)" else "N/A" end
    )|\(.spec.storageClassName // "N/A")"
  ' | while IFS='|' read -r pv cap phase claim sc; do
    local color="${C_GREEN}"
    [[ "$phase" != "Bound" && "$phase" != "Available" ]] && { color="${C_YELLOW}"; pv_warn=1; }
    printf "  ${color}%-45s %-12s %-12s %-20s %-20s${C_RESET}\n" \
      "$pv" "$cap" "$phase" "${claim:0:19}" "$sc"
  done

  [[ "$pv_warn" -eq 1 ]] && mark_warn "PVs in non-Bound/non-Available state detected"
  echo
}

# ==============================================================================
# [19] NODE /SYSROOT DISK USAGE
# ==============================================================================
check_disk_sysroot() {
  section_header "19" "Node Container Runtime Disk Usage (via oc debug)"
  ((CHECKS_RUN++))
  note "Threshold: ${DISK_WARN_THRESHOLD}% — flags high usage. This may take a few minutes."
  echo
  printf "  ${C_CYAN}%-44s %-10s %-10s %-10s %-8s %-20s${C_RESET}\n" \
    "NODE" "SIZE" "USED" "AVAIL" "USE%" "MOUNT"
  printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────"

  for role_label in "node-role.kubernetes.io/master=" "node-role.kubernetes.io/infra=" "node-role.kubernetes.io/worker="; do
    local role="${role_label%%=*}"; role="${role##*/}"
    local nodes
    nodes=$(oc get nodes -l "$role_label" -o name 2>/dev/null | awk -F'/' '{print $2}')
    [[ -z "$nodes" ]] && continue
    printf "\n  ${C_BLUE}── Role: %s ──${C_RESET}\n" "$role"

    for node in $nodes; do
      local output
      output=$(timeout 30s oc debug node/"$node" --quiet -- bash -c '
        for path in /host/var/lib/containers /host/var/lib/containerd /host; do
          [ -d "$path" ] && df -h "$path" | tail -n1 && break
        done
      ' 2>/dev/null)

      if [[ -z "$output" ]]; then
        printf "  ${C_RED}%-44s  ERROR (debug failed or timed out)${C_RESET}\n" "$node"
        continue
      fi

      read -r fs size used avail use_pct mount <<< "$output"
      local pct_num="${use_pct//%/}"
      local color="${C_GREEN}"
      compare_gt "${pct_num:-0}" "$DISK_WARN_THRESHOLD" && {
        color="${C_RED}"
        mark_warn "High disk usage on $node ($use_pct)"
      }
      printf "  ${color}%-44s %-10s %-10s %-10s %-8s %-20s${C_RESET}\n" \
        "$node" "$size" "$used" "$avail" "$use_pct" "$mount"
    done
  done
  echo
}

# ==============================================================================
# [20] RECENT WARNING EVENTS
# ==============================================================================
check_events() {
  section_header "20" "Recent Warning Events (last 25)"
  ((CHECKS_RUN++))
  info "Non-Normal events, sorted by lastTimestamp..."
  echo
  printf "  ${C_CYAN}%-22s %-10s %-35s %-28s %-40s${C_RESET}\n" \
    "NAMESPACE" "TYPE" "REASON" "OBJECT" "MESSAGE"
  printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

  oc get events -A --sort-by='.lastTimestamp' 2>/dev/null | \
  grep -v "Normal" | tail -n 25 | \
  while read -r ns _seen _seen2 type reason obj _from msg; do
    printf "  ${C_YELLOW}%-22s %-10s %-35s %-28s %-40s${C_RESET}\n" \
      "$ns" "$type" "$reason" "$obj" "${msg:0:39}"
  done
  echo
}

# ==============================================================================
# [21] ROUTE HEALTH
# ==============================================================================
check_routes() {
  section_header "21" "Application Route Health (HTTP Probe)"
  ((CHECKS_RUN++))
  info "Probing routes (excl. openshift*/kube* namespaces)..."
  echo
  printf "  ${C_CYAN}%-35s %-42s %-10s %-10s${C_RESET}\n" "NAMESPACE" "ROUTE" "HTTP" "TIME(s)"
  printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────────────"

  local route_warn=0
  while IFS='|' read -r ns route host; do
    [[ -z "$host" ]] && continue
    local proto="http"
    oc get route "$route" -n "$ns" -o jsonpath='{.spec.tls.termination}' 2>/dev/null | \
      grep -q . && proto="https"

    local result status_code time_total color
    result=$(curl -k -L -s -o /dev/null \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -w "%{http_code}|%{time_total}" \
      "$proto://$host" 2>/dev/null || printf "000|0")

    status_code="${result%%|*}"
    time_total="${result##*|}"
    color="${C_GREEN}"
    [[ ! "$status_code" =~ ^[23] ]] && { color="${C_RED}"; route_warn=1; }

    printf "  ${color}%-35s %-42s %-10s %-10s${C_RESET}\n" \
      "$ns" "$route" "$status_code" "$time_total"
  done < <(
    oc get route --all-namespaces 2>/dev/null \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.host}{"\n"}{end}' | \
    grep -Ev "^($EXCLUDE_NS_REGEX)"
  )

  [[ "$route_warn" -eq 1 ]] && mark_warn "One or more application routes returned non-2xx/3xx"
  [[ "$route_warn" -eq 0 ]] && pass "All probed routes returned healthy HTTP status codes."
  echo
}

# ==============================================================================
# [22] EGRESSIP
# ==============================================================================
check_egressip() {
  section_header "22" "EgressIP Health & Assignment"
  ((CHECKS_RUN++))

  info "Egress-assignable nodes:"
  oc get nodes -l k8s.ovn.org/egress-assignable='' \
    -o 'custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address,READY:.status.conditions[?(@.type=="Ready")].status' \
    --no-headers 2>/dev/null || printf "  ${C_YELLOW}No egress-assignable nodes found.${C_RESET}\n"
  echo

  info "EgressIP Resources:"
  oc get egressips -A \
    -o custom-columns=NAME:.metadata.name,IP:.status.items[*].egressIP,NODE:.status.items[*].node \
    --no-headers 2>/dev/null || printf "  ${C_YELLOW}No EgressIP resources found.${C_RESET}\n"
  echo

  info "Duplicate EgressIP Check:"
  local dupes
  dupes=$(oc get egressips -A \
    -o jsonpath='{range .items[*]}{.status.items[*].egressIP}{"\n"}{end}' 2>/dev/null | \
    sort | uniq -d)
  if [[ -n "$dupes" ]]; then
    fail "Duplicate EgressIPs: $dupes"
    mark_warn "Duplicate EgressIPs detected"
  else
    pass "No duplicate EgressIPs."
  fi
  echo

  info "EgressIP Unassigned Check:"
  local unassigned
  unassigned=$(oc get egressips \
    -o 'custom-columns=NAME:.metadata.name,ASSIGNED:.status.items[*].egressIP' \
    --no-headers 2>/dev/null | \
    awk '$2 == "" || $2 == "<none>" {print $1 " has NO assigned IP/Node"}')
  if [[ -n "$unassigned" ]]; then
    while read -r line; do printf "  ${C_YELLOW}⚠️  %s${C_RESET}\n" "$line"; done <<< "$unassigned"
    mark_warn "Unassigned EgressIPs detected"
  else
    pass "All EgressIPs are assigned."
  fi
  echo
}

# ==============================================================================
# FINAL SUMMARY
# ==============================================================================
print_summary() {
  echo
  printf "${C_CYAN}${C_BOLD}%s${C_RESET}\n" "╔══════════════════════════════════════════════════════════════╗"
  printf "${C_CYAN}${C_BOLD}%s${C_RESET}\n" "║                   🏁  CHECK SUMMARY                         ║"
  printf "${C_CYAN}${C_BOLD}%s${C_RESET}\n" "╚══════════════════════════════════════════════════════════════╝"
  echo
  printf "  ${C_WHITE}%-18s${C_RESET} %s\n" "Checks Run"     "$CHECKS_RUN"
  printf "  ${C_MAGENTA}%-18s${C_RESET} %s\n" "Checks Skipped" "$CHECKS_SKIPPED"
  printf "  ${C_YELLOW}%-18s${C_RESET} %s\n" "Warnings"       "$WARN_COUNT"
  printf "  ${C_RED}%-18s${C_RESET} %s\n"    "Failures"       "$FAIL_COUNT"
  printf "  ${C_MAGENTA}%-18s${C_RESET} %s\n" "Artifacts"     "$ARTIFACT_DIR"
  echo

  if [[ "$WARN_COUNT" -gt 0 ]]; then
    printf "  ${C_YELLOW}${C_BOLD}⚠️  WARNINGS:${C_RESET}\n"
    for w in "${WARN_ITEMS[@]}"; do
      printf "  ${C_YELLOW}   → %s${C_RESET}\n" "$w"
    done
    echo
  fi

  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    printf "  ${C_RED}${C_BOLD}❌ FAILURES:${C_RESET}\n"
    for f in "${FAIL_ITEMS[@]}"; do
      printf "  ${C_RED}   → %s${C_RESET}\n" "$f"
    done
    echo
  fi

  printf "  ${C_CYAN}${C_BOLD}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────"
  if [[ "$EXIT_CODE" -eq 0 ]]; then
    printf "  ${C_GREEN}${C_BOLD}✅ RESULT: PASS — Cluster appears ready for upgrade${C_RESET}\n"
  elif [[ "$EXIT_CODE" -eq 1 ]]; then
    printf "  ${C_YELLOW}${C_BOLD}⚠️  RESULT: WARNING — Review warnings before upgrading${C_RESET}\n"
  else
    printf "  ${C_RED}${C_BOLD}❌ RESULT: FAILED — Fix critical issues before upgrading${C_RESET}\n"
  fi
  printf "  ${C_CYAN}${C_BOLD}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────"

  # Artifact index
  if [[ -d "$ARTIFACT_DIR" ]]; then
    echo
    printf "  ${C_MAGENTA}${C_BOLD}📁 Artifact Files Generated:${C_RESET}\n"
    while IFS= read -r f; do
      local sz
      sz=$(du -sh "$f" 2>/dev/null | cut -f1)
      printf "  ${C_MAGENTA}   %-60s (%s)${C_RESET}\n" "$f" "$sz"
    done < <(find "$ARTIFACT_DIR" -type f | sort)
  fi
  echo
}

# ==============================================================================
# MAIN — Functional dispatch (toggle RUN_* flags at top to control execution)
# ==============================================================================
main() {
  prereq_check
  print_header

  [[ "$RUN_CLUSTER_VERSION"      == "true" ]] && check_cluster_version      || skipped_section "01" "Cluster Version & Upgrade Status"
  [[ "$RUN_CLUSTER_OPERATORS"    == "true" ]] && check_cluster_operators    || skipped_section "02" "Cluster Operators Health"
  [[ "$RUN_OLM_OPERATORS"        == "true" ]] && check_olm_operators        || skipped_section "03" "OLM Operators (CSV)"
  [[ "$RUN_NODE_STATUS"          == "true" ]] && check_node_status          || skipped_section "04" "Node Status"
  [[ "$RUN_NODE_RESOURCES"       == "true" ]] && check_node_resources       || skipped_section "05" "Node CPU & Memory Usage"
  [[ "$RUN_MCP_STATUS"           == "true" ]] && check_mcp_status           || skipped_section "06" "MCP Status + MC Match/Mismatch"
  [[ "$RUN_CONTROL_PLANE_LABELS" == "true" ]] && check_control_plane_labels || skipped_section "07" "Control Plane Labels"
  [[ "$RUN_API_ETCD_PODS"        == "true" ]] && check_api_etcd_pods        || skipped_section "08" "API Server & ETCD Pods"
  [[ "$RUN_ETCD_HEALTH"          == "true" ]] && check_etcd_health          || skipped_section "09" "ETCD Operator Conditions & Latency"
  [[ "$RUN_ETCD_MEMBER_HEALTH"   == "true" ]] && check_etcd_member_health   || skipped_section "10" "ETCD Member Health (etcdctl)"
  [[ "$RUN_WEBHOOKS"             == "true" ]] && check_webhooks             || skipped_section "11" "Admission Webhooks"
  [[ "$RUN_DEPRECATED_APIS"      == "true" ]] && check_deprecated_apis      || skipped_section "12" "Deprecated APIs"
  [[ "$RUN_CERTIFICATES"         == "true" ]] && check_certificates         || skipped_section "13" "TLS Certificates"
  [[ "$RUN_PENDING_CSRS"         == "true" ]] && check_pending_csrs         || skipped_section "14" "Pending CSRs"
  [[ "$RUN_CRITICAL_ALERTS"      == "true" ]] && check_critical_alerts      || skipped_section "15" "Critical Prometheus Alerts"
  [[ "$RUN_WORKLOADS"            == "true" ]] && check_workloads            || skipped_section "16" "Workload Health + Artifacts"
  [[ "$RUN_PDB"                  == "true" ]] && check_pdb                  || skipped_section "17" "PDB Analysis"
  [[ "$RUN_PVC"                  == "true" ]] && check_pvc                  || skipped_section "18" "PVC & PV Health"
  [[ "$RUN_DISK_SYSROOT"         == "true" ]] && check_disk_sysroot         || skipped_section "19" "Node Disk Usage"
  [[ "$RUN_EVENTS"               == "true" ]] && check_events               || skipped_section "20" "Recent Events"
  [[ "$RUN_ROUTES"               == "true" ]] && check_routes               || skipped_section "21" "Route Health"
  [[ "$RUN_EGRESSIP"             == "true" ]] && check_egressip             || skipped_section "22" "EgressIP Health"

  print_summary
}

main
exit "$EXIT_CODE"
