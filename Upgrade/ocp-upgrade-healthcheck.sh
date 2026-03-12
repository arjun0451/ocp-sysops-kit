#!/usr/bin/env bash
# ==============================================================================
# Script  : ocp-upgrade-healthcheck.sh
# Version : 5.0
# Author  : Arjun / ocp-sysops-kit
# Desc    : Comprehensive OpenShift Upgrade Pre-flight & Health Check Suite.
#           Functional-execution model — comment/uncomment sections to control
#           which checks run. Each check is a self-contained bash function.
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
# ██████╗UN/COMMENT CHECKS BELOW TO ENABLE OR DISABLE
# ==============================================================================
# Set RUN_<CHECK>=true to enable, false to disable
# ------------------------------------------------------------------------------

RUN_CLUSTER_VERSION=true          # [01] Cluster Version & Upgrade Status
RUN_CLUSTER_OPERATORS=true        # [02] Cluster Operators Health
RUN_OLM_OPERATORS=true            # [03] OLM / CSV Operator Status
RUN_NODE_STATUS=true              # [04] Node Ready Status
RUN_NODE_RESOURCES=true           # [05] Node CPU & Memory Usage (via oc debug)
RUN_MCP_STATUS=true               # [06] Machine Config Pool Status + MC Match/Mismatch + Auto-Fix hint
RUN_CONTROL_PLANE_LABELS=true     # [07] Control Plane Node Labels
RUN_API_ETCD_PODS=true            # [08] API Server & ETCD Pod Health
RUN_ETCD_HEALTH=true              # [09] ETCD Operator Health & Disk Fsync Latency
RUN_WEBHOOKS=true                 # [10] Admission Webhook Validation
RUN_DEPRECATED_APIS=true          # [11] Deprecated API Usage
RUN_CERTIFICATES=true             # [12] TLS Certificate Expiry (<30 days)
RUN_WORKLOADS=true                # [13] Workload Pod Health + Replica Counts + Namespace Summary
RUN_PDB=true                      # [14] Pod Disruption Budget Analysis
RUN_PVC=true                      # [15] PVC & PV Health
RUN_DISK_SYSROOT=true             # [16] Node /sysroot Disk Usage (via oc debug)
RUN_EVENTS=true                   # [17] Recent Warning Events
RUN_ROUTES=true                   # [18] Application Route Health (HTTP probe)
RUN_EGRESSIP=true                 # [19] EgressIP Assignment & Duplicate Check

# ==============================================================================
# CONFIGURATION
# ==============================================================================
EXCLUDE_NS_REGEX="^(openshift|kube)"
CERT_EXPIRY_DAYS=30
CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=15
CPU_MEM_THRESHOLD=70              # % threshold for node CPU/mem high-usage highlight
DISK_WARN_THRESHOLD=80            # % threshold for /sysroot disk usage warning

# ==============================================================================
# INTERNAL TRACKING
# ==============================================================================
EXIT_CODE=0
WARN_COUNT=0
FAIL_COUNT=0
WARN_ITEMS=()
FAIL_ITEMS=()
CHECKS_RUN=0
CHECKS_SKIPPED=0

# ==============================================================================
# ANSI COLORS
# ==============================================================================
if [[ -t 1 && $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  C_RESET="\e[0m"; C_BOLD="\e[1m"
  C_CYAN="\e[36m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"
  C_RED="\e[31m";  C_BLUE="\e[34m"; C_MAGENTA="\e[35m"
  C_WHITE="\e[97m"; C_ORANGE="\e[38;5;208m"
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
  local idx="$1" title="$2" total="$3"
  echo
  echo -e "${C_CYAN}${C_BOLD}══════════════════════════════════════════════════════════════${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}  [$idx/$total] $title${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}══════════════════════════════════════════════════════════════${C_RESET}"
}

skipped_section() {
  local idx="$1" title="$2" total="$3"
  echo -e "${C_MAGENTA}  [$idx/$total] ⏭  SKIPPED: $title${C_RESET}"
  ((CHECKS_SKIPPED++))
}

pass()  { echo -e "  ${C_GREEN}✅ $*${C_RESET}"; }
warn()  { echo -e "  ${C_YELLOW}⚠️  $*${C_RESET}"; }
fail()  { echo -e "  ${C_RED}❌ $*${C_RESET}"; }
info()  { echo -e "  ${C_WHITE}🔎 $*${C_RESET}"; }
note()  { echo -e "  ${C_BLUE}ℹ️  $*${C_RESET}"; }

# calc: bc with awk fallback
bc_calc() {
  local expr="$1"
  if command -v bc &>/dev/null; then
    echo "scale=1; $expr" | bc
  else
    awk "BEGIN {printf \"%.1f\", $expr}"
  fi
}

compare_gt() {
  local val="$1" thr="$2"
  if command -v bc &>/dev/null; then
    [[ $(echo "$val > $thr" | bc) -eq 1 ]]
  else
    awk -v v="$val" -v t="$thr" 'BEGIN{exit !(v>t)}'
  fi
}

convert_to_mib() {
  local value="$1"
  local unit="${value//[0-9.]/}"
  local num="${value%$unit}"
  case "$unit" in
    Gi) bc_calc "$num * 1024" ;;
    Mi) echo "$num" ;;
    Ki) bc_calc "$num / 1024" ;;
    *)  echo "0.0" ;;
  esac
}

# ==============================================================================
# PREREQUISITES
# ==============================================================================
prereq_check() {
  local missing=0
  for cmd in oc jq openssl base64 curl; do
    if ! command -v "$cmd" &>/dev/null; then
      echo -e "${C_RED}❌ Missing required command: $cmd${C_RESET}"
      ((missing++))
    fi
  done
  [[ "$missing" -gt 0 ]] && { echo -e "${C_RED}Install missing tools and re-run.${C_RESET}"; exit 3; }
  if ! oc whoami &>/dev/null; then
    echo -e "${C_RED}❌ Not logged into OpenShift. Run: oc login${C_RESET}"; exit 3
  fi
}

# ==============================================================================
# REPORT HEADER
# ==============================================================================
print_header() {
  # Count enabled checks
  local total=0
  for var in RUN_CLUSTER_VERSION RUN_CLUSTER_OPERATORS RUN_OLM_OPERATORS RUN_NODE_STATUS \
             RUN_NODE_RESOURCES RUN_MCP_STATUS RUN_CONTROL_PLANE_LABELS RUN_API_ETCD_PODS \
             RUN_ETCD_HEALTH RUN_WEBHOOKS RUN_DEPRECATED_APIS RUN_CERTIFICATES \
             RUN_WORKLOADS RUN_PDB RUN_PVC RUN_DISK_SYSROOT RUN_EVENTS RUN_ROUTES RUN_EGRESSIP; do
    [[ "${!var}" == "true" ]] && ((total++))
  done
  TOTAL_ENABLED=$total

  echo
  echo -e "${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}║       🚀  OPENSHIFT UPGRADE PRE-FLIGHT HEALTH CHECK          ║${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}║                   ocp-sysops-kit v5.0                        ║${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
  echo
  echo -e "  ${C_WHITE}📅 Date       :${C_RESET} $(date)"
  echo -e "  ${C_WHITE}👤 User       :${C_RESET} $(oc whoami)"
  echo -e "  ${C_WHITE}🔗 API Server :${C_RESET} $(oc whoami --show-server)"
  echo -e "  ${C_WHITE}📋 Checks     :${C_RESET} $TOTAL_ENABLED / 19 enabled"
  echo
  echo -e "${C_RED}${C_BOLD}  🛑 PRE-CHECK REMINDER:${C_RESET}"
  echo -e "${C_RED}     ➤ Have you taken an ETCD BACKUP before proceeding?${C_RESET}"
  echo -e "${C_RED}     ➤ Is your upgrade path validated on: https://access.redhat.com/labs/ocpupgradegraph/${C_RESET}"
  echo
}

# ==============================================================================
# [01] CLUSTER VERSION
# ==============================================================================
check_cluster_version() {
  section_header "01" "Cluster Version & Upgrade Status" 19
  ((CHECKS_RUN++))
  oc get clusterversion 2>/dev/null || mark_fail "Unable to query ClusterVersion"

  local cv_json
  cv_json=$(oc get clusterversion version -o json 2>/dev/null)
  if [[ -n "$cv_json" ]]; then
    local channel available_updates
    channel=$(echo "$cv_json" | jq -r '.spec.channel // "N/A"')
    available_updates=$(echo "$cv_json" | jq -r '.status.availableUpdates // [] | length')
    note "Channel          : $channel"
    note "Available updates: $available_updates"
    [[ "$available_updates" -gt 0 ]] && echo "$cv_json" | jq -r '.status.availableUpdates[] | "    → \(.version) [\(.channels | join(", "))]"'
  fi
  echo
}

# ==============================================================================
# [02] CLUSTER OPERATORS
# ==============================================================================
check_cluster_operators() {
  section_header "02" "Cluster Operators Health" 19
  ((CHECKS_RUN++))
  info "Pattern: Available=True, Progressing=False, Degraded=False"
  local co_issues
  co_issues=$(oc get co --no-headers 2>/dev/null | grep -v -E "True\s+False\s+False" || true)
  if [[ -n "$co_issues" ]]; then
    printf "  ${C_YELLOW}%-45s %-10s %-12s %-10s${C_RESET}\n" "OPERATOR" "AVAILABLE" "PROGRESSING" "DEGRADED"
    echo -e "  ${C_YELLOW}──────────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo "$co_issues" | awk -v Y="${C_YELLOW}" -v R="${C_RESET}" '{printf "  "Y"%-45s %-10s %-12s %-10s"R"\n", $1,$2,$3,$4}'
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
  section_header "03" "OLM Operators (ClusterServiceVersions)" 19
  ((CHECKS_RUN++))
  info "Checking CSVs not in 'Succeeded' phase..."
  local csv_issues
  csv_issues=$(oc get csv -A --no-headers 2>/dev/null | grep -v Succeeded || true)
  if [[ -n "$csv_issues" ]]; then
    printf "  ${C_YELLOW}%-45s %-45s %-15s${C_RESET}\n" "NAMESPACE" "CSV NAME" "PHASE"
    echo -e "  ${C_YELLOW}─────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo "$csv_issues" | awk -v Y="${C_YELLOW}" -v R="${C_RESET}" '{printf "  "Y"%-45s %-45s %-15s"R"\n", $1,$2,$NF}'
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
  section_header "04" "Node Status" 19
  ((CHECKS_RUN++))
  printf "  ${C_CYAN}%-50s %-10s %-20s %-15s${C_RESET}\n" "NODE" "ROLE" "STATUS" "VERSION"
  echo -e "  ${C_CYAN}─────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"
  oc get nodes --no-headers 2>/dev/null | while read -r name status roles age version; do
    local color="$C_GREEN"
    [[ "$status" != "Ready" ]] && color="$C_RED"
    printf "  ${color}%-50s %-10s %-20s %-15s${C_RESET}\n" "$name" "$roles" "$status" "$version"
  done

  local node_issues
  node_issues=$(oc get nodes --no-headers | grep -v " Ready " || true)
  if [[ -n "$node_issues" ]]; then
    mark_warn "One or more nodes not in Ready state"
  else
    echo
    pass "All nodes are Ready."
  fi
  echo
}

# ==============================================================================
# [05] NODE CPU & MEMORY USAGE
# ==============================================================================
check_node_resources() {
  section_header "05" "Node CPU & Memory Usage" 19
  ((CHECKS_RUN++))
  note "Threshold: ${CPU_MEM_THRESHOLD}% for CPU and Memory"
  note "Uses 'oc adm top nodes' (requires metrics-server). Fallback: oc debug."
  echo

  if oc adm top nodes &>/dev/null 2>&1; then
    printf "  ${C_CYAN}%-50s %-14s %-14s %-14s %-14s${C_RESET}\n" \
      "NODE" "CPU(cores)" "CPU%" "MEMORY(bytes)" "MEMORY%"
    echo -e "  ${C_CYAN}─────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"
    oc adm top nodes --no-headers 2>/dev/null | while read -r node cpu cpu_pct mem mem_pct; do
      local cpu_val="${cpu_pct//%/}" mem_val="${mem_pct//%/}"
      local color="$C_GREEN"
      local notes=""
      compare_gt "$cpu_val" "$CPU_MEM_THRESHOLD" && { color="$C_RED"; notes+="[HIGH CPU] "; }
      compare_gt "$mem_val" "$CPU_MEM_THRESHOLD" && { color="$C_RED"; notes+="[HIGH MEM] "; }
      printf "  ${color}%-50s %-14s %-14s %-14s %-14s %-10s${C_RESET}\n" \
        "$node" "$cpu" "$cpu_pct" "$mem" "$mem_pct" "$notes"
    done
  else
    warn "Metrics API unavailable (oc adm top failed). Falling back to oc debug..."
    mark_warn "Metrics API unavailable — node resource check degraded"

    printf "  ${C_CYAN}%-42s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-20s${C_RESET}\n" \
      "NODE" "MEM TOTAL" "MEM USED" "MEM FREE" "MEM AVAIL" "CPU%USER" "CPU%SYS" "CPU%IDLE" "NOTES"
    echo -e "  ${C_CYAN}─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"

    for role_label in "node-role.kubernetes.io/master=" "node-role.kubernetes.io/infra=" "node-role.kubernetes.io/worker="; do
      local role="${role_label%%=*}"; role="${role##*/}"
      echo -e "\n  ${C_BLUE}── Role: $role ──${C_RESET}"
      local nodes
      nodes=$(oc get nodes -l "$role_label" -o name 2>/dev/null | awk -F'/' '{print $2}')
      [[ -z "$nodes" ]] && { note "No $role nodes found."; continue; }

      for node in $nodes; do
        local mem_out cpu_out mem_total mem_used mem_free mem_avail
        mem_out=$(timeout 30s oc debug node/"$node" -- chroot /host free -h 2>/dev/null | grep "Mem:" | awk '{print $2, $3, $4, $7}')
        if [[ -z "$mem_out" ]]; then
          printf "  ${C_RED}%-42s %-10s${C_RESET}\n" "$node" "MEM ERROR"
          continue
        fi
        read -r mem_total mem_used mem_free mem_avail <<< "$mem_out"

        local mem_total_mib mem_used_mib mem_pct notes="" color="$C_GREEN"
        mem_total_mib=$(convert_to_mib "$mem_total")
        mem_used_mib=$(convert_to_mib "$mem_used")
        if [[ "$mem_total_mib" != "0.0" ]]; then
          mem_pct=$(bc_calc "($mem_used_mib / $mem_total_mib) * 100")
          compare_gt "$mem_pct" "$CPU_MEM_THRESHOLD" && { notes+="[HIGH MEM ${mem_pct}%] "; color="$C_RED"; }
        fi

        cpu_out=$(timeout 30s oc debug node/"$node" -- chroot /host sar -u 1 1 2>/dev/null | \
          grep "Average:" | grep -v "CPU" | awk '{print $3, $5, $8}')
        [[ -z "$cpu_out" ]] && cpu_out=$(timeout 30s oc debug node/"$node" -- chroot /host \
          top -bn1 2>/dev/null | grep '%Cpu' | awk '{print $2, $4, $8}')
        local cpu_user="N/A" cpu_sys="N/A" cpu_idle="N/A"
        if [[ -n "$cpu_out" ]]; then
          read -r cpu_user cpu_sys cpu_idle <<< "$cpu_out"
          local cpu_total
          cpu_total=$(bc_calc "${cpu_user:-0} + ${cpu_sys:-0}")
          compare_gt "$cpu_total" "$CPU_MEM_THRESHOLD" && { notes+="[HIGH CPU ${cpu_total}%] "; color="$C_RED"; }
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
# [06] MCP STATUS + MC MATCH/MISMATCH + FIX HINT
# ==============================================================================
check_mcp_status() {
  section_header "06" "Machine Config Pool (MCP) Status & Node MC Match/Mismatch" 19
  ((CHECKS_RUN++))

  # ── 6a: MCP Overview ──────────────────────────────────────────────────────
  info "MCP Pool Overview:"
  echo
  oc get mcp 2>/dev/null
  echo

  # ── 6b: Paused / Degraded MCP check ──────────────────────────────────────
  info "Checking for Paused or Degraded MCPs..."
  local mcp_issues
  mcp_issues=$(oc get mcp -o json 2>/dev/null | jq -r '
    .items[] |
    select(.spec.paused==true or .status.degradedMachineCount > 0) |
    "⚠️  MCP \(.metadata.name): Paused=\(.spec.paused), DegradedCount=\(.status.degradedMachineCount)"
  ' || true)

  if [[ -n "$mcp_issues" ]]; then
    echo -e "${C_RED}$mcp_issues${C_RESET}"
    mark_fail "MCP is paused or has degraded machines"
  else
    pass "No paused or degraded MCPs found."
  fi
  echo

  # ── 6c: maxUnavailable Summary ────────────────────────────────────────────
  info "MCP maxUnavailable Settings:"
  printf "  ${C_CYAN}%-20s %-18s %-12s %-12s %-12s %-12s %-12s${C_RESET}\n" \
    "MCP" "MAX_UNAVAILABLE" "MACHINE_CNT" "UPDATED" "READY" "DEGRADED" "PAUSED"
  echo -e "  ${C_CYAN}──────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"
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
    local color="$C_GREEN"
    [[ "$degraded" -gt 0 ]] && color="$C_RED"
    [[ "$paused" == "true" ]] && color="$C_YELLOW"
    printf "  ${color}%-20s %-18s %-12s %-12s %-12s %-12s %-12s${C_RESET}\n" \
      "$mcp" "$max_un" "$total" "$updated" "$ready" "$degraded" "$paused"
  done
  echo

  # ── 6d: Node-level MC Match/Mismatch Table ────────────────────────────────
  info "Node Machine Config Match Status (per-node):"
  printf "  ${C_CYAN}%-50s %-38s %-38s %-12s %-12s${C_RESET}\n" \
    "NODE" "CURRENT MC" "DESIRED MC" "MC STATE" "STATUS"
  echo -e "  ${C_CYAN}──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"

  local mismatch_found=false
  oc get nodes -o json 2>/dev/null | jq -r '
    .items | sort_by(.metadata.name) | .[] |
    {
      name: .metadata.name,
      current:  (.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] // "N/A"),
      desired:  (.metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] // "N/A"),
      state:    (.metadata.annotations["machineconfiguration.openshift.io/state"] // "N/A")
    } |
    "\(.name)|\(.current)|\(.desired)|\(.state)|\(if .current == .desired then "Match" else "Mismatch" end)"
  ' | while IFS='|' read -r node current desired state status; do
    local color="$C_GREEN"
    [[ "$status" == "Mismatch" ]] && color="$C_RED"
    [[ "$state" != "Done" && "$state" != "N/A" ]] && color="$C_YELLOW"
    printf "  ${color}%-50s %-38s %-38s %-12s %-12s${C_RESET}\n" \
      "$node" "${current:0:37}" "${desired:0:37}" "$state" "$status"
  done

  # ── 6e: Mismatch detection + fix guidance ─────────────────────────────────
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
    warn "MC Mismatch detected on the following nodes:"
    echo "$mismatches" | while read -r node; do
      echo -e "  ${C_RED}  → $node${C_RESET}"
    done
    echo
    echo -e "${C_YELLOW}${C_BOLD}  ── HOW TO DIAGNOSE & FIX ────────────────────────────────────────${C_RESET}"
    echo -e "${C_YELLOW}  Step 1: Check MCO pod logs for errors:${C_RESET}"
    echo -e "${C_WHITE}    oc logs -n openshift-machine-config-operator -l k8s-app=machine-config-daemon --tail=100${C_RESET}"
    echo
    echo -e "${C_YELLOW}  Step 2: Check MCD pod status on affected node (example):${C_RESET}"
    echo -e "${C_WHITE}    NODE=<node-name>${C_RESET}"
    echo -e "${C_WHITE}    oc get pod -n openshift-machine-config-operator -l k8s-app=machine-config-daemon --field-selector spec.nodeName=\$NODE${C_RESET}"
    echo
    echo -e "${C_YELLOW}  Step 3: View node MCD log directly:${C_RESET}"
    echo -e "${C_WHITE}    oc logs -n openshift-machine-config-operator -l k8s-app=machine-config-daemon -c machine-config-daemon --field-selector spec.nodeName=\$NODE${C_RESET}"
    echo
    echo -e "${C_YELLOW}  Step 4: If MCD is stuck, force a drain + restart:${C_RESET}"
    echo -e "${C_WHITE}    oc adm drain \$NODE --ignore-daemonsets --delete-emptydir-data${C_RESET}"
    echo -e "${C_WHITE}    oc adm uncordon \$NODE${C_RESET}"
    echo
    echo -e "${C_YELLOW}  Step 5: Force MCO to re-render and reapply config:${C_RESET}"
    echo -e "${C_WHITE}    oc annotate node \$NODE machineconfiguration.openshift.io/currentConfig- --overwrite${C_RESET}"
    echo -e "${C_WHITE}    # This clears currentConfig annotation forcing MCO to re-evaluate${C_RESET}"
    echo
    echo -e "${C_YELLOW}  Step 6: Verify MCP status converges:${C_RESET}"
    echo -e "${C_WHITE}    watch oc get mcp${C_RESET}"
    echo -e "${C_YELLOW}${C_BOLD}  ─────────────────────────────────────────────────────────────────${C_RESET}"
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
  section_header "07" "Control Plane Node Labels" 19
  ((CHECKS_RUN++))
  local control_nodes
  control_nodes=$(oc get nodes -l node-role.kubernetes.io/master= -o name 2>/dev/null || \
                  oc get nodes -l node-role.kubernetes.io/control-plane= -o name 2>/dev/null)
  local label_issues=0
  for node in $control_nodes; do
    if ! oc get "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null | \
         grep -q 'node-role.kubernetes.io/control-plane'; then
      warn "$node is MISSING label 'node-role.kubernetes.io/control-plane'"
      ((label_issues++))
      mark_warn "Control-plane node missing label"
    else
      local node_name="${node#node/}"
      pass "$node_name has 'node-role.kubernetes.io/control-plane' label."
    fi
  done
  [[ "$label_issues" -eq 0 ]] && pass "Control-plane label check passed for all master nodes."
  echo
}

# ==============================================================================
# [08] API SERVER & ETCD PODS
# ==============================================================================
check_api_etcd_pods() {
  section_header "08" "API Server & ETCD Pod Health" 19
  ((CHECKS_RUN++))

  for ns_label in "openshift-apiserver:API Server" "openshift-etcd:ETCD"; do
    local ns="${ns_label%%:*}" label="${ns_label##*:}"
    info "Checking $label pods in namespace: $ns"
    local bad_pods
    bad_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep -v -E "Running|Completed" || true)
    if [[ -n "$bad_pods" ]]; then
      printf "  ${C_RED}%-60s %-15s %-15s${C_RESET}\n" "POD" "STATUS" "RESTARTS"
      echo "$bad_pods" | awk -v R="${C_RED}" -v RS="${C_RESET}" '{printf "  "R"%-60s %-15s %-15s"RS"\n", $1,$3,$4}'
      mark_fail "$label pods not Running"
    else
      pass "All $label pods are Running."
    fi
    echo
  done
}

# ==============================================================================
# [09] ETCD HEALTH & LATENCY
# ==============================================================================
check_etcd_health() {
  section_header "09" "ETCD Operator Health & Disk Fsync Latency" 19
  ((CHECKS_RUN++))

  local etcd_json
  etcd_json=$(oc get etcd cluster -o json 2>/dev/null || true)
  if [[ -z "$etcd_json" ]]; then
    fail "CRITICAL: Unable to fetch ETCD cluster object"
    mark_fail "Cannot fetch ETCD operator status"
  else
    etcd_cond() { echo "$etcd_json" | jq -r --arg T "$1" '.status.conditions[] | select(.type==$T) | .status'; }

    local members_avail members_deg pods_avail ep_deg node_deg
    members_avail=$(etcd_cond "EtcdMembersAvailable")
    members_deg=$(etcd_cond "EtcdMembersDegraded")
    pods_avail=$(etcd_cond "StaticPodsAvailable")
    ep_deg=$(etcd_cond "EtcdEndpointsDegraded")
    node_deg=$(etcd_cond "NodeControllerDegraded")

    printf "  ${C_CYAN}%-35s %s${C_RESET}\n" "CONDITION" "STATUS"
    echo -e "  ${C_CYAN}──────────────────────────────────────────────${C_RESET}"

    for row in \
      "EtcdMembersAvailable:$members_avail:expect_true" \
      "EtcdMembersDegraded:$members_deg:expect_false" \
      "StaticPodsAvailable:$pods_avail:expect_true" \
      "EtcdEndpointsDegraded:$ep_deg:expect_false" \
      "NodeControllerDegraded:$node_deg:expect_false"; do
      local cond="${row%%:*}" val="${row#*:}"; val="${val%:*}"
      local expect="${row##*:}"
      local color="$C_GREEN"
      { [[ "$expect" == "expect_true" && "$val" != "True" ]] || \
        [[ "$expect" == "expect_false" && "$val" == "True" ]]; } && color="$C_RED"
      printf "  ${color}%-35s %s${C_RESET}\n" "$cond" "$val"
    done

    local etcd_fail=false
    [[ "$members_avail" != "True" || "$members_deg" == "True" || \
       "$pods_avail" != "True"  || "$ep_deg" == "True" || "$node_deg" == "True" ]] && etcd_fail=true

    echo
    if $etcd_fail; then
      fail "ETCD is NOT in a healthy state — DO NOT UPGRADE"
      mark_fail "ETCD core health conditions failed"
    else
      pass "ETCD core health conditions are healthy."
    fi

    local progressing
    progressing=$(echo "$etcd_json" | jq -r '
      .status.conditions[] |
      select(.type | endswith("Progressing")) |
      select(.status=="True") | .type')
    if [[ -n "$progressing" ]]; then
      warn "ETCD controllers still progressing:"
      echo "$progressing" | sed "s/^/    ${C_YELLOW}→ /" | sed "s/$/${C_RESET}/"
      mark_warn "ETCD controllers progressing"
    fi
  fi
  echo

  # Latency check via Prometheus
  if oc get ns openshift-monitoring &>/dev/null; then
    info "ETCD WAL Fsync Latency check (via Prometheus). Threshold: >20ms"
    local prom_pod
    prom_pod=$(oc -n openshift-monitoring get pod \
      -l app.kubernetes.io/name=prometheus,prometheus=k8s \
      --field-selector=status.phase=Running \
      -o name 2>/dev/null | head -n1 | cut -d/ -f2)

    if [[ -n "$prom_pod" ]]; then
      local result
      result=$(oc -n openshift-monitoring exec -c prometheus "$prom_pod" -- \
        curl -s -G 'http://localhost:9090/api/v1/query' \
        --data-urlencode 'query=histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))' 2>/dev/null)

      if [[ -z "$result" ]]; then
        warn "Prometheus query failed — skipping fsync latency check."
        mark_warn "ETCD fsync latency check failed"
      else
        local high_lat
        high_lat=$(echo "$result" | jq -r '
          .data.result[] |
          select(.value[1] | tonumber > 0.02) |
          "  ⚠️  Instance \(.metric.instance // "unknown") — Latency: \(.value[1])s (Threshold: 0.020s)"')
        if [[ -n "$high_lat" ]]; then
          echo -e "${C_RED}$high_lat${C_RESET}"
          mark_warn "ETCD fsync latency exceeds 20ms threshold"
        else
          pass "ETCD WAL fsync latency is within healthy limits (p99 < 20ms)."
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
# [10] ADMISSION WEBHOOKS
# ==============================================================================
check_webhooks() {
  section_header "10" "Admission Webhooks (Upgrade Blockers)" 19
  ((CHECKS_RUN++))
  info "Checking for webhooks pointing to missing services or empty endpoints..."
  local failed=0

  for wh_config in $(oc get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null); do
    local svc_data
    svc_data=$(oc get "$wh_config" -o json 2>/dev/null | \
      jq -r '.webhooks[]?.clientConfig.service | select(. != null) | "\(.namespace) \(.name)"' | sort -u)

    [[ -z "$svc_data" ]] && continue

    while read -r ns name; do
      if ! oc get service "$name" -n "$ns" &>/dev/null; then
        fail "Webhook '$wh_config' → MISSING service '$ns/$name'"
        ((failed++))
        mark_fail "Broken admission webhook: missing service"
      else
        local ep_count
        ep_count=$(oc get endpoints "$name" -n "$ns" \
          -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
        if [[ "$ep_count" -eq 0 ]]; then
          warn "Webhook '$wh_config' → service '$ns/$name' has NO ENDPOINTS"
          mark_warn "Webhook service has no ready endpoints"
        fi
      fi
    done <<< "$svc_data"
  done

  [[ "$failed" -eq 0 ]] && pass "No broken webhook configurations detected."
  echo
}

# ==============================================================================
# [11] DEPRECATED APIS
# ==============================================================================
check_deprecated_apis() {
  section_header "11" "Deprecated API Usage" 19
  ((CHECKS_RUN++))
  info "Scanning APIRequestCounts for removedInRelease + recent usage..."
  local deprecated
  deprecated=$(oc get apirequestcounts 2>/dev/null | awk '
    NR>1 && $2 != "" && $4 > 0 {
      printf "%-60s %-15s %-10s\n", $1, $2, $4
    }')
  if [[ -n "$deprecated" ]]; then
    printf "  ${C_YELLOW}%-60s %-20s %-10s${C_RESET}\n" "API RESOURCE" "REMOVED IN" "REQ (24h)"
    echo -e "  ${C_YELLOW}────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_YELLOW}$deprecated${C_RESET}"
    note "Fix: update client manifests to use current API versions before upgrading."
    mark_warn "Deprecated API usage detected — clients must be updated"
  else
    pass "No deprecated API usage detected."
  fi
  echo
}

# ==============================================================================
# [12] TLS CERTIFICATES
# ==============================================================================
check_certificates() {
  section_header "12" "TLS Certificates Expiring < ${CERT_EXPIRY_DAYS} days" 19
  ((CHECKS_RUN++))
  info "Scanning all TLS secrets across all namespaces..."
  local cert_warn=0

  oc get secrets -A --field-selector=type=kubernetes.io/tls -o json 2>/dev/null | \
  jq -r '.items[] | select(.data."tls.crt" != null) | "\(.metadata.namespace) \(.metadata.name) \(.data."tls.crt")"' | \
  while read -r ns name cert_data; do
    local enddate exp_ts now_ts diff
    enddate=$(echo "$cert_data" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [[ -z "$enddate" ]] && continue
    exp_ts=$(date -d "$enddate" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$enddate" +%s 2>/dev/null)
    now_ts=$(date +%s)
    [[ -z "$exp_ts" ]] && continue
    diff=$(( (exp_ts - now_ts) / 86400 ))
    if [[ "$diff" -le "$CERT_EXPIRY_DAYS" ]]; then
      local color="$C_YELLOW"
      [[ "$diff" -le 7 ]] && color="$C_RED"
      echo -e "  ${color}⚠️  $ns/$name — expires in ${diff} day(s) ($enddate)${C_RESET}"
      cert_warn=1
    fi
  done

  [[ "$cert_warn" -eq 1 ]] && mark_warn "TLS certificates expiring within ${CERT_EXPIRY_DAYS} days"
  pass "Certificate expiry scan complete."
  echo
}

# ==============================================================================
# [13] WORKLOAD HEALTH
# ==============================================================================
check_workloads() {
  section_header "13" "Workload Health (Pods, Deployments, StatefulSets)" 19
  ((CHECKS_RUN++))

  # ── 13a: Non-running pods (top 20) ────────────────────────────────────────
  info "Pods not in Running/Succeeded phase (top 20):"
  local unhealthy_pods
  unhealthy_pods=$(oc get pods -A -o json 2>/dev/null | jq -r '
    .items[] |
    select(
      .status.phase != "Succeeded" and
      (
        .status.phase != "Running" or
        any(.status.containerStatuses[]?; .ready == false)
      )
    ) |
    "\(.metadata.namespace)/\(.metadata.name) | \(.status.phase) | \(
      .status.containerStatuses[0].state.waiting.reason //
      .status.containerStatuses[0].state.terminated.reason //
      "NotReady"
    )"
  ' | head -n 20)

  if [[ -n "$unhealthy_pods" ]]; then
    printf "  ${C_YELLOW}%-70s %-15s %-20s${C_RESET}\n" "POD (NAMESPACE/NAME)" "PHASE" "REASON"
    echo -e "  ${C_YELLOW}──────────────────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo "$unhealthy_pods" | while IFS='|' read -r pod phase reason; do
      printf "  ${C_YELLOW}%-70s %-15s %-20s${C_RESET}\n" "${pod// /}" "${phase// /}" "${reason// /}"
    done
    mark_warn "Unhealthy pods detected"
  else
    pass "No unhealthy pods detected."
  fi
  echo

  # ── 13b: Deployment/StatefulSet replica mismatches ────────────────────────
  info "Deployments/StatefulSets with mismatched replicas:"
  local ds_warn=0
  oc get deploy,statefulset -A --no-headers 2>/dev/null | while read -r ns name ready age; do
    IFS='/' read -r actual desired <<< "$ready"
    if [[ "$actual" != "$desired" ]]; then
      echo -e "  ${C_YELLOW}⚠️  $ns/$name — Replicas: $ready${C_RESET}"
      ds_warn=1
    fi
  done
  [[ "$ds_warn" -eq 0 ]] && pass "All Deployments/StatefulSets have matching replicas."
  echo

  # ── 13c: Namespace pod summary (excluding openshift/kube) ─────────────────
  info "Pod health summary per namespace (excluding openshift* / kube*):"
  printf "  ${C_CYAN}%-38s %-10s %-20s %-15s${C_RESET}\n" "NAMESPACE" "TOTAL" "RUNNING/HEALTHY" "UNHEALTHY"
  echo -e "  ${C_CYAN}───────────────────────────────────────────────────────────────────────────────────${C_RESET}"
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
    local color="$C_GREEN"
    [[ "$not_healthy" -gt 0 ]] && { color="$C_YELLOW"; pod_warn=1; }
    printf "  ${color}%-38s %-10s %-20s %-15s${C_RESET}\n" "$ns" "$total" "$healthy" "$not_healthy"
  done < <(oc get namespace -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -Ev "$EXCLUDE_NS_REGEX")
  [[ "$pod_warn" -eq 1 ]] && mark_warn "Unhealthy application pods detected"
  echo
}

# ==============================================================================
# [14] PDB ANALYSIS
# ==============================================================================
check_pdb() {
  section_header "14" "Pod Disruption Budget (PDB) Analysis" 19
  ((CHECKS_RUN++))
  note "Formula: minAvailable → disruptionsAllowed = currentHealthy - minAvailable"
  note "         maxUnavailable → disruptionsAllowed = maxUnavailable - (expectedPods - currentHealthy)"
  echo

  local tmp_json
  tmp_json=$(mktemp)
  oc get pdb -A -o json 2>/dev/null > "$tmp_json"

  local table
  table=$(jq -r '
    .items[] |
    select(.metadata.namespace | test("^openshift") | not) |
    {
      ns: .metadata.namespace,
      name: .metadata.name,
      expected: .status.expectedPods,
      healthy: .status.currentHealthy,
      minAvailable: .spec.minAvailable,
      maxUnavailable: .spec.maxUnavailable
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

  printf "  ${C_CYAN}%-40s %-35s %-15s %-10s %-10s %-12s %-12s${C_RESET}\n" \
    "NAMESPACE" "PDB NAME" "TYPE" "EXPECTED" "HEALTHY" "DISRUPTIONS" "DISRUPT%"
  echo -e "  ${C_CYAN}────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"

  local blocked=0 full_outage=0 safe=0 low_ha=0 total=0

  while IFS='|' read -r color ns name type exp healthy da pct; do
    local c="$C_GREEN"
    case "$color" in
      RED)    c="$C_RED";    ((blocked++)) ;;
      BLUE)   c="$C_BLUE";   ((full_outage++)) ;;
      ORANGE) c="$C_ORANGE"; ((low_ha++)) ;;
      GREEN)  c="$C_GREEN";  ((safe++)) ;;
    esac
    ((total++))
    printf "  ${c}%-40s %-35s %-15s %-10s %-10s %-12s %-12s${C_RESET}\n" \
      "$ns" "$name" "$type" "$exp" "$healthy" "$da" "$pct"
  done <<< "$table"

  echo
  [[ "$full_outage" -gt 0 ]] && \
    echo -e "  ${C_ORANGE}${C_BOLD}⚠️  WARNING: $full_outage PDB(s) allow 100% disruption — full service outage possible during maintenance!${C_RESET}"

  echo
  echo -e "  ${C_BOLD}📊 PDB Summary:${C_RESET}"
  echo -e "  ${C_RED}   Blocked (0 disruptions allowed)   : $blocked${C_RESET}"
  echo -e "  ${C_ORANGE}   Low HA / Caution (<30% disruption): $low_ha${C_RESET}"
  echo -e "  ${C_GREEN}   Safe for maintenance              : $safe${C_RESET}"
  echo -e "  ${C_BLUE}   Full outage allowed (100%)        : $full_outage${C_RESET}"
  echo -e "  ${C_WHITE}   Total PDBs analyzed               : $total${C_RESET}"

  [[ "$blocked" -gt 0 ]] && mark_fail "PDB(s) blocking all disruptions — upgrade will be stuck"
  rm -f "$tmp_json"
  echo
}

# ==============================================================================
# [15] PVC / PV HEALTH
# ==============================================================================
check_pvc() {
  section_header "15" "PV & PVC Health" 19
  ((CHECKS_RUN++))

  info "Non-Bound PVCs:"
  local pvc_issues
  pvc_issues=$(oc get pvc -A --no-headers 2>/dev/null | grep -v "Bound" || true)
  if [[ -n "$pvc_issues" ]]; then
    printf "  ${C_YELLOW}%-40s %-35s %-15s %-15s${C_RESET}\n" "NAMESPACE" "PVC NAME" "STATUS" "CAPACITY"
    echo -e "  ${C_YELLOW}───────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo "$pvc_issues" | awk -v Y="${C_YELLOW}" -v R="${C_RESET}" '{printf "  "Y"%-40s %-35s %-15s %-15s"R"\n",$1,$2,$3,$4}'
    mark_warn "Non-Bound PVCs detected"
  else
    pass "All PVCs are Bound."
  fi
  echo

  info "PVCs stuck in Terminating:"
  local pvc_term
  pvc_term=$(oc get pvc -A --no-headers 2>/dev/null | grep "Terminating" || true)
  if [[ -n "$pvc_term" ]]; then
    echo -e "${C_RED}$pvc_term${C_RESET}"
    mark_warn "PVCs stuck in Terminating state"
  else
    pass "No PVCs stuck in Terminating."
  fi
  echo
}

# ==============================================================================
# [16] NODE /SYSROOT DISK USAGE
# ==============================================================================
check_disk_sysroot() {
  section_header "16" "Node /sysroot & Container Runtime Disk Usage" 19
  ((CHECKS_RUN++))
  note "Uses 'oc debug node'. This may take a few minutes for large clusters."
  echo
  printf "  ${C_CYAN}%-42s %-10s %-10s %-10s %-10s %-12s${C_RESET}\n" \
    "NODE" "SIZE" "USED" "AVAIL" "USE%" "PATH"
  echo -e "  ${C_CYAN}──────────────────────────────────────────────────────────────────────────────────${C_RESET}"

  for role_label in "node-role.kubernetes.io/master=" "node-role.kubernetes.io/infra=" "node-role.kubernetes.io/worker="; do
    local role="${role_label%%=*}"; role="${role##*/}"
    local nodes
    nodes=$(oc get nodes -l "$role_label" -o name 2>/dev/null | awk -F'/' '{print $2}')
    [[ -z "$nodes" ]] && continue
    echo -e "\n  ${C_BLUE}── Role: $role ──${C_RESET}"

    for node in $nodes; do
      local output fs size used avail use_pct mount
      output=$(timeout 30s oc debug node/"$node" --quiet -- bash -c '
        for path in /host/var/lib/containers /host/var/lib/containerd /host; do
          if [ -d "$path" ]; then
            df -h "$path" | tail -n1
            break
          fi
        done
      ' 2>/dev/null)

      if [[ -z "$output" ]]; then
        printf "  ${C_RED}%-42s %-10s${C_RESET}\n" "$node" "ERROR"
        continue
      fi

      read -r fs size used avail use_pct mount <<< "$output"
      local pct_num="${use_pct//%/}"
      local color="$C_GREEN"
      compare_gt "${pct_num:-0}" "$DISK_WARN_THRESHOLD" && { color="$C_RED"; mark_warn "High disk usage on $node ($use_pct)"; }

      printf "  ${color}%-42s %-10s %-10s %-10s %-10s %-12s${C_RESET}\n" \
        "$node" "$size" "$used" "$avail" "$use_pct" "$mount"
    done
  done
  echo
}

# ==============================================================================
# [17] RECENT EVENTS
# ==============================================================================
check_events() {
  section_header "17" "Recent Warning Events (last 20)" 19
  ((CHECKS_RUN++))
  info "Showing non-Normal events, sorted by timestamp..."
  echo
  printf "  ${C_CYAN}%-20s %-15s %-45s %-25s %-40s${C_RESET}\n" \
    "NAMESPACE" "TYPE" "REASON" "OBJECT" "MESSAGE"
  echo -e "  ${C_CYAN}──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"

  oc get events -A --sort-by='.lastTimestamp' 2>/dev/null | \
  grep -v "Normal" | tail -n 20 | \
  while read -r ns last_seen type reason obj _ msg; do
    local color="$C_YELLOW"
    [[ "$type" == "Warning" ]] && color="$C_YELLOW"
    printf "  ${color}%-20s %-15s %-45s %-25s %-40s${C_RESET}\n" \
      "$ns" "$type" "$reason" "$obj" "${msg:0:39}"
  done
  echo
}

# ==============================================================================
# [18] ROUTE HEALTH
# ==============================================================================
check_routes() {
  section_header "18" "Application Route Health (HTTP Probe)" 19
  ((CHECKS_RUN++))
  info "Probing application routes (excluding openshift*/kube* namespaces)..."
  echo
  printf "  ${C_CYAN}%-35s %-42s %-10s %-10s${C_RESET}\n" "NAMESPACE" "ROUTE" "HTTP CODE" "TIME(s)"
  echo -e "  ${C_CYAN}──────────────────────────────────────────────────────────────────────────────────────────────────────────────${C_RESET}"

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
      "$proto://$host" 2>/dev/null || echo "000|0")

    status_code="${result%%|*}"
    time_total="${result##*|}"
    color="$C_GREEN"
    [[ ! "$status_code" =~ ^[23] ]] && { color="$C_RED"; route_warn=1; }

    printf "  ${color}%-35s %-42s %-10s %-10s${C_RESET}\n" "$ns" "$route" "$status_code" "$time_total"
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
# [19] EGRESSIP
# ==============================================================================
check_egressip() {
  section_header "19" "EgressIP Health & Assignment" 19
  ((CHECKS_RUN++))

  info "Egress-assignable nodes:"
  oc get nodes -l k8s.ovn.org/egress-assignable='' \
    -o 'custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address,READY:.status.conditions[?(@.type=="Ready")].status' \
    --no-headers 2>/dev/null || echo -e "  ${C_YELLOW}No egress-assignable nodes found.${C_RESET}"
  echo

  info "EgressIP Resources:"
  oc get egressips -A \
    -o custom-columns=NAME:.metadata.name,IP:.status.items[*].egressIP,NODE:.status.items[*].node \
    --no-headers 2>/dev/null || echo -e "  ${C_YELLOW}No EgressIP resources found.${C_RESET}"
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
    awk '$2 == "" || $2 == "<none>" {print "⚠️  " $1 " has NO assigned IP/Node"}')
  if [[ -n "$unassigned" ]]; then
    echo -e "${C_YELLOW}$unassigned${C_RESET}"
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
  echo -e "${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}║                   🏁  CHECK SUMMARY                         ║${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
  echo
  echo -e "  ${C_WHITE}Checks Run     : ${CHECKS_RUN}${C_RESET}"
  echo -e "  ${C_MAGENTA}Checks Skipped : ${CHECKS_SKIPPED}${C_RESET}"
  echo -e "  ${C_YELLOW}Warnings       : ${WARN_COUNT}${C_RESET}"
  echo -e "  ${C_RED}Failures       : ${FAIL_COUNT}${C_RESET}"
  echo

  if [[ "$WARN_COUNT" -gt 0 ]]; then
    echo -e "  ${C_YELLOW}${C_BOLD}⚠️  WARNINGS:${C_RESET}"
    for w in "${WARN_ITEMS[@]}"; do
      echo -e "  ${C_YELLOW}   → $w${C_RESET}"
    done
    echo
  fi

  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo -e "  ${C_RED}${C_BOLD}❌ FAILURES:${C_RESET}"
    for f in "${FAIL_ITEMS[@]}"; do
      echo -e "  ${C_RED}   → $f${C_RESET}"
    done
    echo
  fi

  echo -e "  ${C_CYAN}${C_BOLD}──────────────────────────────────────────────────────────────${C_RESET}"
  if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo -e "  ${C_GREEN}${C_BOLD}✅ RESULT: PASS — Cluster appears ready for upgrade${C_RESET}"
  elif [[ "$EXIT_CODE" -eq 1 ]]; then
    echo -e "  ${C_YELLOW}${C_BOLD}⚠️  RESULT: WARNING — Review warnings before upgrading${C_RESET}"
  else
    echo -e "  ${C_RED}${C_BOLD}❌ RESULT: FAILED — Fix critical issues before upgrading${C_RESET}"
  fi
  echo -e "  ${C_CYAN}${C_BOLD}──────────────────────────────────────────────────────────────${C_RESET}"
  echo
}

# ==============================================================================
# MAIN — Functional dispatch (comment/uncomment RUN_* flags at top of script)
# ==============================================================================
main() {
  prereq_check
  print_header

  [[ "$RUN_CLUSTER_VERSION"     == "true" ]] && check_cluster_version     || skipped_section "01" "Cluster Version & Upgrade Status" 19
  [[ "$RUN_CLUSTER_OPERATORS"   == "true" ]] && check_cluster_operators   || skipped_section "02" "Cluster Operators Health" 19
  [[ "$RUN_OLM_OPERATORS"       == "true" ]] && check_olm_operators       || skipped_section "03" "OLM Operators (CSV)" 19
  [[ "$RUN_NODE_STATUS"         == "true" ]] && check_node_status         || skipped_section "04" "Node Status" 19
  [[ "$RUN_NODE_RESOURCES"      == "true" ]] && check_node_resources      || skipped_section "05" "Node CPU & Memory Usage" 19
  [[ "$RUN_MCP_STATUS"          == "true" ]] && check_mcp_status          || skipped_section "06" "MCP Status + MC Match/Mismatch" 19
  [[ "$RUN_CONTROL_PLANE_LABELS" == "true" ]] && check_control_plane_labels || skipped_section "07" "Control Plane Labels" 19
  [[ "$RUN_API_ETCD_PODS"       == "true" ]] && check_api_etcd_pods       || skipped_section "08" "API Server & ETCD Pods" 19
  [[ "$RUN_ETCD_HEALTH"         == "true" ]] && check_etcd_health         || skipped_section "09" "ETCD Health & Latency" 19
  [[ "$RUN_WEBHOOKS"            == "true" ]] && check_webhooks            || skipped_section "10" "Admission Webhooks" 19
  [[ "$RUN_DEPRECATED_APIS"     == "true" ]] && check_deprecated_apis     || skipped_section "11" "Deprecated APIs" 19
  [[ "$RUN_CERTIFICATES"        == "true" ]] && check_certificates        || skipped_section "12" "TLS Certificates" 19
  [[ "$RUN_WORKLOADS"           == "true" ]] && check_workloads           || skipped_section "13" "Workload Health" 19
  [[ "$RUN_PDB"                 == "true" ]] && check_pdb                 || skipped_section "14" "PDB Analysis" 19
  [[ "$RUN_PVC"                 == "true" ]] && check_pvc                 || skipped_section "15" "PVC / PV Health" 19
  [[ "$RUN_DISK_SYSROOT"        == "true" ]] && check_disk_sysroot        || skipped_section "16" "Node Disk Usage" 19
  [[ "$RUN_EVENTS"              == "true" ]] && check_events              || skipped_section "17" "Recent Events" 19
  [[ "$RUN_ROUTES"              == "true" ]] && check_routes              || skipped_section "18" "Route Health" 19
  [[ "$RUN_EGRESSIP"            == "true" ]] && check_egressip            || skipped_section "19" "EgressIP Health" 19

  print_summary
}

main
exit "$EXIT_CODE"
