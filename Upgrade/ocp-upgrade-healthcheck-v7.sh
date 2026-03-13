#!/usr/bin/env bash
# ==============================================================================
# Script  : ocp-upgrade-healthcheck.sh
# Version : 7.0
# Author  : Arjun / ocp-sysops-kit
# Desc    : OpenShift Upgrade Pre-flight & Health Check Suite
#           25 checks — clean structured output, GUI-aware formatting
#
# What's new in v7.0:
#   [NEW-1] Hardware Compatibility reminder check (hypervisor / platform aware)
#   [NEW-2] Cloud Credential Operator (CCO) mode + policy manifest guidance
#   [NEW-3] Third-party CSI driver compatibility detection
#   [FMT]   Reformatted all section output — clean aligned, no symbol clutter
#   [FMT]   Section headers use CHECK XX/25 format (parsed by server.js)
#   [FMT]   pass/warn/fail helpers use [PASS]/[WARN]/[FAIL] tags
#   [FIX]   Sidebar fail/warn counts wired to [FAIL]/[WARN] tags
#
# Exit codes: 0=PASS  1=WARNING  2=FAILED  3=PREREQ ERROR
# ==============================================================================

set -u
set -o pipefail

# ==============================================================================
# TOGGLE CHECKS
# ==============================================================================
RUN_CLUSTER_VERSION=true          # [01] Cluster Version & Upgrade Status
RUN_CLUSTER_OPERATORS=true        # [02] Cluster Operators Health
RUN_OLM_OPERATORS=true            # [03] OLM / CSV Operator Status
RUN_NODE_STATUS=true              # [04] Node Ready Status
RUN_NODE_RESOURCES=true           # [05] Node CPU & Memory Usage
RUN_MCP_STATUS=true               # [06] MCP Status + MC Match/Mismatch
RUN_CONTROL_PLANE_LABELS=true     # [07] Control Plane Node Labels
RUN_API_ETCD_PODS=true            # [08] API Server & ETCD Pod Health
RUN_ETCD_HEALTH=true              # [09] ETCD Operator Conditions & WAL Latency
RUN_ETCD_MEMBER_HEALTH=true       # [10] ETCD Member Health (etcdctl)
RUN_WEBHOOKS=true                 # [11] Admission Webhook Validation
RUN_DEPRECATED_APIS=true          # [12] Deprecated API Usage
RUN_CERTIFICATES=true             # [13] TLS Certificate Expiry
RUN_PENDING_CSRS=true             # [14] Pending CSR Detection
RUN_CRITICAL_ALERTS=true          # [15] Critical Prometheus Alerts
RUN_WORKLOADS=true                # [16] Workload Pod Health
RUN_PDB=true                      # [17] Pod Disruption Budget Analysis
RUN_PVC=true                      # [18] PVC & PV Health
RUN_DISK_SYSROOT=true             # [19] Node Disk Usage
RUN_EVENTS=true                   # [20] Recent Warning Events
RUN_ROUTES=true                   # [21] Application Route Health
RUN_EGRESSIP=true                 # [22] EgressIP Assignment
RUN_HW_COMPAT=true                # [23] Hardware Compatibility Reminder  [NEW]
RUN_CLOUD_CREDS=true              # [24] Cloud Credential Operator Check  [NEW]
RUN_CSI_COMPAT=true               # [25] Third-party CSI Driver Check     [NEW]

TOTAL_CHECKS=25

# ==============================================================================
# CONFIGURATION
# ==============================================================================
EXCLUDE_NS_REGEX="^(openshift|kube)"
CERT_EXPIRY_DAYS=30
CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=15
CPU_MEM_THRESHOLD=70
DISK_WARN_THRESHOLD=80
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
# ANSI COLORS
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

# Tagged output helpers — tags parsed by server.js for sidebar status and counts
pass()  { printf "${C_GREEN}  [PASS]  %s${C_RESET}\n" "$*"; }
warn()  { printf "${C_YELLOW}  [WARN]  %s${C_RESET}\n" "$*"; }
fail()  { printf "${C_RED}  [FAIL]  %s${C_RESET}\n" "$*"; }
info()  { printf "${C_CYAN}  [INFO]  %s${C_RESET}\n" "$*"; }
note()  { printf "${C_WHITE}  [NOTE]  %s${C_RESET}\n" "$*"; }
guide() { printf "${C_BLUE}  [CMD]   %s${C_RESET}\n" "$*"; }
artifact_note() { printf "${C_MAGENTA}  [FILE]  %s${C_RESET}\n" "$*"; }

div_heavy() { printf "${C_CYAN}${C_BOLD}  %s${C_RESET}\n" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
div_light() { printf "${C_CYAN}  %s${C_RESET}\n" "────────────────────────────────────────────────────────────"; }
col_sep()   { printf "  ${C_CYAN}%s${C_RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────"; }

# Section header — format "  CHECK XX/25  Title" is parsed by server.js parseLineMeta
section_header() {
  local idx="$1" title="$2"
  echo
  div_heavy
  printf "${C_CYAN}${C_BOLD}  CHECK %02d/%02d  %s${C_RESET}\n" "$idx" "$TOTAL_CHECKS" "$title"
  div_heavy
  echo
}

skipped_section() {
  local idx="$1" title="$2"
  printf "${C_MAGENTA}  [SKIP]  %02d/%02d  %s${C_RESET}\n" "$idx" "$TOTAL_CHECKS" "$title"
  ((CHECKS_SKIPPED++))
}

bc_calc() {
  if command -v bc &>/dev/null; then echo "scale=1; $1" | bc
  else awk "BEGIN {printf \"%.1f\", $1}"; fi
}
compare_gt() {
  if command -v bc &>/dev/null; then [[ $(echo "$1 > $2" | bc) -eq 1 ]]
  else awk -v v="$1" -v t="$2" 'BEGIN{exit !(v>t)}'; fi
}
convert_to_mib() {
  local value="$1" unit num
  unit="${value//[0-9.]/}"; num="${value%"$unit"}"
  case "$unit" in
    Gi) bc_calc "$num * 1024" ;; Mi) echo "$num" ;;
    Ki) bc_calc "$num / 1024" ;; *)  echo "0.0" ;;
  esac
}

# ==============================================================================
# PREREQUISITES
# ==============================================================================
prereq_check() {
  local missing=0
  for cmd in oc jq openssl base64 curl; do
    command -v "$cmd" &>/dev/null || { printf "${C_RED}  [FAIL]  Missing: %s${C_RESET}\n" "$cmd"; ((missing++)); }
  done
  [[ "$missing" -gt 0 ]] && { printf "${C_RED}  Install missing tools and re-run.\n${C_RESET}"; exit 3; }
  oc whoami &>/dev/null || { printf "${C_RED}  [FAIL]  Not logged into OpenShift. Run: oc login${C_RESET}\n"; exit 3; }
  mkdir -p "$ARTIFACT_DIR"
  artifact_note "Artifact directory: $ARTIFACT_DIR"
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
             RUN_PDB RUN_PVC RUN_DISK_SYSROOT RUN_EVENTS RUN_ROUTES RUN_EGRESSIP \
             RUN_HW_COMPAT RUN_CLOUD_CREDS RUN_CSI_COMPAT; do
    [[ "${!var}" == "true" ]] && ((enabled++))
  done

  echo
  printf "${C_CYAN}${C_BOLD}  %-62s${C_RESET}\n" "╔══════════════════════════════════════════════════════════╗"
  printf "${C_CYAN}${C_BOLD}  %-62s${C_RESET}\n" "║    OPENSHIFT UPGRADE PRE-FLIGHT HEALTH CHECK SUITE       ║"
  printf "${C_CYAN}${C_BOLD}  %-62s${C_RESET}\n" "║                  ocp-sysops-kit  v7.0                    ║"
  printf "${C_CYAN}${C_BOLD}  %-62s${C_RESET}\n" "╚══════════════════════════════════════════════════════════╝"
  echo
  printf "  ${C_WHITE}%-20s${C_RESET} %s\n" "Date"       "$(date)"
  printf "  ${C_WHITE}%-20s${C_RESET} %s\n" "User"       "$(oc whoami)"
  printf "  ${C_WHITE}%-20s${C_RESET} %s\n" "API Server" "$(oc whoami --show-server)"
  printf "  ${C_WHITE}%-20s${C_RESET} %d / %d enabled\n" "Checks" "$enabled" "$TOTAL_CHECKS"
  printf "  ${C_WHITE}%-20s${C_RESET} %s\n" "Artifacts"  "$ARTIFACT_DIR"
  echo
  div_light
  printf "${C_RED}${C_BOLD}  PRE-UPGRADE REMINDERS${C_RESET}\n"
  div_light
  printf "${C_RED}  1.  Take an ETCD backup before proceeding.${C_RESET}\n"
  printf "${C_RED}  2.  Validate upgrade path: https://access.redhat.com/labs/ocpupgradegraph/${C_RESET}\n"
  printf "${C_RED}  3.  Confirm hardware/hypervisor compatibility for the target version.${C_RESET}\n"
  printf "${C_RED}  4.  Review release notes for breaking changes.${C_RESET}\n"
  echo
}

# ==============================================================================
# [01] CLUSTER VERSION
# ==============================================================================
check_cluster_version() {
  section_header 1 "Cluster Version & Upgrade Status"
  ((CHECKS_RUN++))

  local cv_json
  cv_json=$(oc get clusterversion version -o json 2>/dev/null)
  if [[ -z "$cv_json" ]]; then
    fail "Unable to query ClusterVersion resource"; mark_fail "ClusterVersion unavailable"; return
  fi

  local version channel available
  version=$(echo "$cv_json" | jq -r '.status.desired.version // "N/A"')
  channel=$(echo "$cv_json" | jq -r '.spec.channel // "N/A"')
  available=$(echo "$cv_json" | jq -r '.status.availableUpdates // [] | length')

  printf "  ${C_WHITE}%-22s${C_RESET} %s\n" "Current Version" "$version"
  printf "  ${C_WHITE}%-22s${C_RESET} %s\n" "Channel"         "$channel"
  printf "  ${C_WHITE}%-22s${C_RESET} %d\n" "Update Targets"  "$available"
  echo

  if [[ "$available" -gt 0 ]]; then
    info "Available upgrade targets:"
    echo "$cv_json" | jq -r '.status.availableUpdates[] |
      "      " + .version + "  [" + (.channels // [] | join(", ")) + "]"'
    echo
  fi

  local progressing degraded
  progressing=$(echo "$cv_json" | jq -r '
    .status.conditions[] | select(.type=="Progressing" and .status=="True") | .message' 2>/dev/null || true)
  degraded=$(echo "$cv_json" | jq -r '
    .status.conditions[] | select(.type=="Degraded" and .status=="True") | .message' 2>/dev/null || true)

  [[ -n "$progressing" ]] && { warn "Cluster progressing: ${progressing:0:100}"; mark_warn "Cluster upgrade in progress"; }
  [[ -n "$degraded"    ]] && { fail "Cluster degraded: ${degraded:0:100}"; mark_fail "ClusterVersion degraded"; }
  [[ -z "$progressing" && -z "$degraded" ]] && pass "Cluster version state is stable."
}

# ==============================================================================
# [02] CLUSTER OPERATORS
# ==============================================================================
check_cluster_operators() {
  section_header 2 "Cluster Operators Health"
  ((CHECKS_RUN++))
  info "Expected: Available=True  Progressing=False  Degraded=False"
  echo

  local co_issues
  co_issues=$(oc get co --no-headers 2>/dev/null | grep -v -E "True[[:space:]]+False[[:space:]]+False" || true)
  if [[ -n "$co_issues" ]]; then
    printf "  ${C_YELLOW}${C_BOLD}%-45s %-12s %-14s %-10s${C_RESET}\n" "OPERATOR" "AVAILABLE" "PROGRESSING" "DEGRADED"
    col_sep
    while read -r name avail prog deg _rest; do
      local color="${C_YELLOW}"; [[ "$deg" == "True" ]] && color="${C_RED}"
      printf "  ${color}%-45s %-12s %-14s %-10s${C_RESET}\n" "$name" "$avail" "$prog" "$deg"
    done <<< "$co_issues"
    echo
    warn "$(echo "$co_issues" | wc -l | tr -d ' ') cluster operator(s) not fully healthy"
    mark_warn "Cluster Operators not all healthy"
  else
    pass "All Cluster Operators: Available=True  Progressing=False  Degraded=False"
  fi
}

# ==============================================================================
# [03] OLM OPERATORS
# ==============================================================================
check_olm_operators() {
  section_header 3 "OLM Operators (ClusterServiceVersions)"
  ((CHECKS_RUN++))
  info "Checking CSVs not in Succeeded phase..."
  echo

  local csv_issues
  csv_issues=$(oc get csv -A --no-headers 2>/dev/null | grep -v Succeeded || true)
  if [[ -n "$csv_issues" ]]; then
    printf "  ${C_YELLOW}${C_BOLD}%-40s %-42s %-15s${C_RESET}\n" "NAMESPACE" "CSV NAME" "PHASE"
    col_sep
    while read -r ns name _rest; do
      printf "  ${C_YELLOW}%-40s %-42s %-15s${C_RESET}\n" "$ns" "$name" "${_rest##* }"
    done <<< "$csv_issues"
    echo
    warn "$(echo "$csv_issues" | wc -l | tr -d ' ') OLM operator(s) not in Succeeded state"
    mark_warn "OLM CSVs not in Succeeded state"
  else
    pass "All OLM CSVs are in Succeeded phase."
  fi
}

# ==============================================================================
# [04] NODE STATUS
# ==============================================================================
check_node_status() {
  section_header 4 "Node Status"
  ((CHECKS_RUN++))

  printf "  ${C_CYAN}${C_BOLD}%-50s %-20s %-12s %-16s${C_RESET}\n" "NODE" "ROLES" "STATUS" "VERSION"
  col_sep

  oc get nodes --no-headers 2>/dev/null | while read -r name status roles _age version; do
    local color="${C_GREEN}"; [[ "$status" != "Ready" ]] && color="${C_RED}"
    printf "  ${color}%-50s %-20s %-12s %-16s${C_RESET}\n" "$name" "$roles" "$status" "$version"
  done

  echo
  local node_issues
  node_issues=$(oc get nodes --no-headers 2>/dev/null | grep -v " Ready " || true)
  if [[ -n "$node_issues" ]]; then
    warn "$(echo "$node_issues" | wc -l | tr -d ' ') node(s) not in Ready state"
    mark_warn "Nodes not in Ready state"
  else
    pass "All nodes are in Ready state."
  fi
}

# ==============================================================================
# [05] NODE CPU & MEMORY USAGE
# ==============================================================================
check_node_resources() {
  section_header 5 "Node CPU & Memory Usage"
  ((CHECKS_RUN++))
  note "Threshold: ${CPU_MEM_THRESHOLD}%  —  values above this are flagged"
  echo

  if oc adm top nodes --no-headers &>/dev/null 2>&1; then
    printf "  ${C_CYAN}${C_BOLD}%-50s %-12s %-8s %-14s %-8s %-12s${C_RESET}\n" \
      "NODE" "CPU(cores)" "CPU%" "MEMORY" "MEM%" "STATUS"
    col_sep
    oc adm top nodes --no-headers 2>/dev/null | while read -r node cpu cpu_pct mem mem_pct; do
      local cpu_val="${cpu_pct//%/}" mem_val="${mem_pct//%/}"
      local color="${C_GREEN}" status="OK"
      compare_gt "${cpu_val:-0}" "$CPU_MEM_THRESHOLD" && { color="${C_RED}"; status="HIGH CPU"; }
      compare_gt "${mem_val:-0}" "$CPU_MEM_THRESHOLD" && { color="${C_RED}"; status="HIGH MEM"; }
      printf "  ${color}%-50s %-12s %-8s %-14s %-8s %-12s${C_RESET}\n" \
        "$node" "$cpu" "$cpu_pct" "$mem" "$mem_pct" "$status"
    done
  else
    warn "Metrics API unavailable — node resource check degraded"
    mark_warn "Metrics API unavailable"
  fi
}

# ==============================================================================
# [06] MCP STATUS
# ==============================================================================
check_mcp_status() {
  section_header 6 "Machine Config Pool (MCP) Status"
  ((CHECKS_RUN++))

  info "MCP Pool Summary:"
  echo
  printf "  ${C_CYAN}${C_BOLD}%-22s %-16s %-10s %-10s %-10s %-10s %-8s${C_RESET}\n" \
    "MCP" "MAX_UNAVAIL" "MACHINES" "UPDATED" "READY" "DEGRADED" "PAUSED"
  col_sep

  oc get mcp -o json 2>/dev/null | jq -r '
    .items[] | [
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
    printf "  ${color}%-22s %-16s %-10s %-10s %-10s %-10s %-8s${C_RESET}\n" \
      "$mcp" "$max_un" "$total" "$updated" "$ready" "$degraded" "$paused"
  done
  echo

  local mcp_issues
  mcp_issues=$(oc get mcp -o json 2>/dev/null | jq -r '
    .items[] | select(.spec.paused==true or .status.degradedMachineCount > 0) |
    "MCP " + .metadata.name + ": Paused=" + (.spec.paused|tostring) +
    "  Degraded=" + (.status.degradedMachineCount|tostring)' || true)
  if [[ -n "$mcp_issues" ]]; then
    while read -r line; do fail "$line"; done <<< "$mcp_issues"
    mark_fail "MCP paused or has degraded machines"
  else
    pass "No paused or degraded MCPs."
  fi
  echo

  info "Node Machine Config Match Status:"
  echo
  printf "  ${C_CYAN}${C_BOLD}%-50s %-12s %-10s${C_RESET}\n" "NODE" "MC STATE" "MATCH"
  col_sep
  oc get nodes -o json 2>/dev/null | jq -r '
    .items | sort_by(.metadata.name) | .[] |
    "\(.metadata.name)|" +
    "\(.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] // "N/A")|" +
    "\(.metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] // "N/A")|" +
    "\(.metadata.annotations["machineconfiguration.openshift.io/state"] // "N/A")"
  ' | while IFS='|' read -r node current desired state; do
    local match="Match"; [[ "$current" != "$desired" ]] && match="Mismatch"
    local color="${C_GREEN}"
    [[ "$match" == "Mismatch" ]] && color="${C_RED}"
    [[ "$state" != "Done" && "$state" != "N/A" ]] && color="${C_YELLOW}"
    printf "  ${color}%-50s %-12s %-10s${C_RESET}\n" "$node" "$state" "$match"
  done

  local mismatches
  mismatches=$(oc get nodes -o json 2>/dev/null | jq -r '
    .items[] |
    select(
      (.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] // "") !=
      (.metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] // "")
    ) | .metadata.name')

  if [[ -n "$mismatches" ]]; then
    echo
    warn "Machine Config mismatch on: $(echo "$mismatches" | tr '\n' ' ')"
    echo
    div_light
    printf "${C_YELLOW}  Remediation${C_RESET}\n"
    div_light
    guide "oc logs -n openshift-machine-config-operator -l k8s-app=machine-config-daemon --tail=100"
    guide "oc adm drain <node> --ignore-daemonsets --delete-emptydir-data && oc adm uncordon <node>"
    guide "oc annotate node <node> machineconfiguration.openshift.io/currentConfig- --overwrite"
    guide "watch oc get mcp"
    echo
    mark_warn "Machine Config mismatch on one or more nodes"
  else
    echo
    pass "All nodes: currentConfig matches desiredConfig."
  fi
}

# ==============================================================================
# [07] CONTROL PLANE LABELS
# ==============================================================================
check_control_plane_labels() {
  section_header 7 "Control Plane Node Labels"
  ((CHECKS_RUN++))

  local control_nodes label_issues=0
  control_nodes=$(oc get nodes -l node-role.kubernetes.io/master= -o name 2>/dev/null || \
                  oc get nodes -l node-role.kubernetes.io/control-plane= -o name 2>/dev/null)

  for node in $control_nodes; do
    if ! oc get "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null | \
         grep -q 'node-role.kubernetes.io/control-plane'; then
      warn "${node#node/}  —  missing label: node-role.kubernetes.io/control-plane"
      ((label_issues++)); mark_warn "Control-plane node missing label"
    else
      pass "${node#node/}  —  control-plane label present"
    fi
  done
  [[ "$label_issues" -eq 0 ]] && pass "Control-plane label check passed for all master nodes."
}

# ==============================================================================
# [08] API SERVER & ETCD PODS
# ==============================================================================
check_api_etcd_pods() {
  section_header 8 "API Server & ETCD Pod Health"
  ((CHECKS_RUN++))

  for ns_label in "openshift-apiserver:API Server" "openshift-etcd:ETCD"; do
    local ns="${ns_label%%:*}" label="${ns_label##*:}"
    info "$label pods  (namespace: $ns)"
    echo
    local bad_pods
    bad_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep -v -E "Running|Completed" || true)
    if [[ -n "$bad_pods" ]]; then
      printf "  ${C_RED}${C_BOLD}%-60s %-15s %-10s${C_RESET}\n" "POD" "STATUS" "RESTARTS"
      col_sep
      while read -r name ready status restarts _age; do
        printf "  ${C_RED}%-60s %-15s %-10s${C_RESET}\n" "$name" "$status" "$restarts"
      done <<< "$bad_pods"
      echo; fail "$label has pods not in Running state"; mark_fail "$label pods not Running"
    else
      pass "All $label pods are Running."
    fi
    echo
  done
}

# ==============================================================================
# [09] ETCD HEALTH
# ==============================================================================
check_etcd_health() {
  section_header 9 "ETCD Operator Conditions & WAL Fsync Latency"
  ((CHECKS_RUN++))

  local etcd_json
  etcd_json=$(oc get etcd cluster -o json 2>/dev/null || true)
  if [[ -z "$etcd_json" ]]; then
    fail "Unable to fetch ETCD cluster object"; mark_fail "ETCD operator status unavailable"; return
  fi

  etcd_cond() { echo "$etcd_json" | jq -r --arg T "$1" \
    '.status.conditions[] | select(.type==$T) | .status'; }

  local members_avail members_deg pods_avail ep_deg node_deg
  members_avail=$(etcd_cond "EtcdMembersAvailable")
  members_deg=$(etcd_cond   "EtcdMembersDegraded")
  pods_avail=$(etcd_cond    "StaticPodsAvailable")
  ep_deg=$(etcd_cond        "EtcdEndpointsDegraded")
  node_deg=$(etcd_cond      "NodeControllerDegraded")

  printf "  ${C_CYAN}${C_BOLD}%-40s %-10s %-8s${C_RESET}\n" "CONDITION" "STATUS" "RESULT"
  col_sep

  local etcd_fail=false
  for row in \
    "EtcdMembersAvailable:${members_avail}:expect_true" \
    "EtcdMembersDegraded:${members_deg}:expect_false" \
    "StaticPodsAvailable:${pods_avail}:expect_true" \
    "EtcdEndpointsDegraded:${ep_deg}:expect_false" \
    "NodeControllerDegraded:${node_deg}:expect_false"; do
    local cond="${row%%:*}" val="${row#*:}"; val="${val%:*}"
    local expect="${row##*:}" result="OK" color="${C_GREEN}"
    if { [[ "$expect" == "expect_true"  && "$val" != "True" ]] || \
         [[ "$expect" == "expect_false" && "$val" == "True"  ]]; }; then
      color="${C_RED}"; etcd_fail=true; result="FAIL"
    fi
    printf "  ${color}%-40s %-10s %-8s${C_RESET}\n" "$cond" "$val" "$result"
  done
  echo

  if $etcd_fail; then
    fail "ETCD health conditions failed — DO NOT UPGRADE"; mark_fail "ETCD core conditions failed"
  else
    pass "ETCD core conditions are healthy."
  fi

  local progressing
  progressing=$(echo "$etcd_json" | jq -r '
    .status.conditions[] | select(.type | endswith("Progressing")) |
    select(.status=="True") | .type' 2>/dev/null || true)
  if [[ -n "$progressing" ]]; then
    echo; warn "ETCD controllers still progressing:"
    while read -r line; do printf "  ${C_YELLOW}       %s${C_RESET}\n" "$line"; done <<< "$progressing"
    mark_warn "ETCD controllers progressing"
  fi
  echo

  if oc get ns openshift-monitoring &>/dev/null; then
    info "ETCD WAL Fsync Latency (p99, threshold: 20ms)"
    local prom_pod
    prom_pod=$(oc -n openshift-monitoring get pod \
      -l app.kubernetes.io/name=prometheus,prometheus=k8s \
      --field-selector=status.phase=Running \
      -o name 2>/dev/null | head -n1 | cut -d/ -f2)
    if [[ -n "$prom_pod" ]]; then
      local result
      result=$(oc -n openshift-monitoring exec -c prometheus "$prom_pod" -- \
        curl -s -G 'http://localhost:9090/api/v1/query' \
        --data-urlencode 'query=histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))' \
        2>/dev/null)
      if [[ -n "$result" ]]; then
        local high_lat
        high_lat=$(echo "$result" | jq -r '
          .data.result[] | select(.value[1] | tonumber > 0.02) |
          "Instance " + (.metric.instance // "unknown") + "  Latency: " + .value[1] + "s  (threshold: 0.020s)"')
        if [[ -n "$high_lat" ]]; then
          while read -r line; do warn "$line"; done <<< "$high_lat"
          mark_warn "ETCD WAL fsync latency exceeds 20ms"
        else
          pass "ETCD WAL fsync latency within limits (p99 < 20ms)."
        fi
      else
        warn "Prometheus query failed — skipping fsync latency check"; mark_warn "ETCD latency check failed"
      fi
    else
      warn "Prometheus pod not found — skipping latency check"; mark_warn "Prometheus unavailable"
    fi
  fi
}

# ==============================================================================
# [10] ETCD MEMBER HEALTH
# ==============================================================================
check_etcd_member_health() {
  section_header 10 "ETCD Member Health (etcdctl)"
  ((CHECKS_RUN++))

  local etcd_pod
  etcd_pod=$(oc get pods -n openshift-etcd -l app=etcd \
    --field-selector="status.phase==Running" \
    -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || true)

  if [[ -z "$etcd_pod" ]]; then
    warn "No running etcd pod found in openshift-etcd."
    mark_warn "ETCD pod not found for etcdctl checks"; return
  fi

  note "Using etcd pod: $etcd_pod"
  echo

  info "ETCD Endpoint Health:"
  echo
  local health_out health_ok=true
  health_out=$(oc exec -n openshift-etcd -c etcdctl "$etcd_pod" -- \
    sh -c "etcdctl endpoint health --cluster" 2>&1 || true)

  if [[ -z "$health_out" ]]; then
    warn "etcdctl endpoint health returned no output"; mark_warn "ETCD endpoint health empty"
  else
    while read -r line; do
      if echo "$line" | grep -q "is healthy"; then
        printf "  ${C_GREEN}  %s${C_RESET}\n" "$line"
      elif echo "$line" | grep -q "is unhealthy\|failed\|error"; then
        printf "  ${C_RED}  %s${C_RESET}\n" "$line"; health_ok=false
      else
        printf "  ${C_WHITE}  %s${C_RESET}\n" "$line"
      fi
    done <<< "$health_out"
    echo
    if $health_ok; then pass "All ETCD endpoints are healthy."
    else fail "One or more ETCD endpoints are unhealthy."; mark_fail "ETCD endpoint health failed"; fi
  fi
  echo

  info "ETCD Endpoint Status:"
  echo
  local status_out
  status_out=$(oc exec -n openshift-etcd -c etcdctl "$etcd_pod" -- \
    sh -c "etcdctl endpoint status -w table" 2>&1 || true)

  if [[ -z "$status_out" ]]; then
    warn "etcdctl endpoint status returned no output"; mark_warn "ETCD status check empty"
  else
    local first=true
    while read -r line; do
      if $first; then printf "  ${C_CYAN}%s${C_RESET}\n" "$line"; first=false
      elif echo "$line" | grep -qi " true "; then printf "  ${C_GREEN}%s  (LEADER)${C_RESET}\n" "$line"
      elif echo "$line" | grep -q "^[|+]"; then printf "  ${C_CYAN}%s${C_RESET}\n" "$line"
      else printf "  ${C_WHITE}%s${C_RESET}\n" "$line"; fi
    done <<< "$status_out"
    echo

    echo "$status_out" | grep -v "^[|+]" | grep -v "ENDPOINT" | \
      awk -F'|' '{gsub(/ /,"",$5); print $5}' | grep -E "^[0-9]" | while read -r sz; do
      local sz_num="${sz//[^0-9.]/}" sz_unit="${sz//[0-9. ]/}" sz_mb=0
      case "$(echo "$sz_unit" | tr '[:upper:]' '[:lower:]')" in gb|gib) sz_mb=$(bc_calc "${sz_num:-0} * 1024") ;; mb|mib) sz_mb="${sz_num:-0}" ;; esac
      if compare_gt "${sz_mb:-0}" "8192"; then
        warn "ETCD DB size is large (${sz}) — consider compaction before upgrade."
        mark_warn "ETCD DB size exceeds 8GB"
      fi
    done
    pass "ETCD endpoint status check complete."
  fi
}

# ==============================================================================
# [11] ADMISSION WEBHOOKS
# ==============================================================================
check_webhooks() {
  section_header 11 "Admission Webhooks (Upgrade Blockers)"
  ((CHECKS_RUN++))
  info "Checking for webhooks with missing services or empty endpoints..."
  echo

  local failed=0
  for wh_config in $(oc get validatingwebhookconfigurations,mutatingwebhookconfigurations \
                       -o name 2>/dev/null); do
    local svc_data
    svc_data=$(oc get "$wh_config" -o json 2>/dev/null | \
      jq -r '.webhooks[]?.clientConfig.service | select(. != null) | "\(.namespace) \(.name)"' | sort -u)
    [[ -z "$svc_data" ]] && continue
    while read -r ns name; do
      if ! oc get service "$name" -n "$ns" &>/dev/null; then
        fail "Webhook ${wh_config}  —  service ${ns}/${name} not found"
        ((failed++)); mark_fail "Broken webhook: missing service $ns/$name"
      else
        local ep_count
        ep_count=$(oc get endpoints "$name" -n "$ns" \
          -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
        if [[ "$ep_count" -eq 0 ]]; then
          warn "Webhook ${wh_config}  —  service ${ns}/${name} has no endpoints"
          mark_warn "Webhook service has no endpoints: $ns/$name"
        fi
      fi
    done <<< "$svc_data"
  done

  [[ "$failed" -eq 0 ]] && pass "No broken webhook configurations detected."
}

# ==============================================================================
# [12] DEPRECATED APIS
# ==============================================================================
check_deprecated_apis() {
  section_header 12 "Deprecated API Usage"
  ((CHECKS_RUN++))
  info "Scanning APIRequestCounts for removed APIs with recent activity..."
  echo

  local deprecated
  deprecated=$(oc get apirequestcounts 2>/dev/null | \
    awk 'NR>1 && $2 != "" && $4 > 0 {printf "%-62s %-18s %-10s\n", $1, $2, $4}')

  if [[ -n "$deprecated" ]]; then
    printf "  ${C_YELLOW}${C_BOLD}%-62s %-18s %-10s${C_RESET}\n" "API RESOURCE" "REMOVED IN" "REQ(24h)"
    col_sep
    while read -r line; do printf "  ${C_YELLOW}%s${C_RESET}\n" "$line"; done <<< "$deprecated"
    echo
    note "Action: update API manifests to current versions before upgrading."
    warn "Deprecated API usage detected — clients must be migrated before upgrade"
    mark_warn "Deprecated APIs in use"
  else
    pass "No deprecated API usage detected."
  fi
}

# ==============================================================================
# [13] TLS CERTIFICATES
# ==============================================================================
check_certificates() {
  section_header 13 "TLS Certificate Expiry (< ${CERT_EXPIRY_DAYS} days)"
  ((CHECKS_RUN++))
  info "Scanning all TLS secrets cluster-wide..."
  echo

  local cert_warn=0 cert_count=0
  while read -r ns name cert_data; do
    local enddate exp_ts now_ts diff
    enddate=$(printf '%s' "$cert_data" | base64 -d 2>/dev/null | \
              openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [[ -z "$enddate" ]] && continue
    exp_ts=$(date -d "$enddate" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$enddate" +%s 2>/dev/null)
    now_ts=$(date +%s); [[ -z "$exp_ts" ]] && continue
    diff=$(( (exp_ts - now_ts) / 86400 ))
    if [[ "$diff" -le "$CERT_EXPIRY_DAYS" ]]; then
      local color="${C_YELLOW}"; [[ "$diff" -le 7 ]] && color="${C_RED}"
      printf "  ${color}  %-40s/%-30s  expires in %d day(s)  (%s)${C_RESET}\n" \
        "$ns" "$name" "$diff" "$enddate"
      ((cert_warn++))
    fi
    ((cert_count++))
  done < <(oc get secrets -A --field-selector=type=kubernetes.io/tls -o json 2>/dev/null | \
    jq -r '.items[] | select(.data."tls.crt" != null) |
            "\(.metadata.namespace) \(.metadata.name) \(.data."tls.crt")"')

  echo
  [[ "$cert_warn" -gt 0 ]] && mark_warn "TLS certificates expiring within ${CERT_EXPIRY_DAYS} days"
  pass "Certificate scan complete  —  ${cert_count} checked,  ${cert_warn} expiring soon."
}

# ==============================================================================
# [14] PENDING CSRs
# ==============================================================================
check_pending_csrs() {
  section_header 14 "Pending Certificate Signing Requests (CSRs)"
  ((CHECKS_RUN++))
  info "Checking for pending CSRs that require approval before upgrade..."
  echo

  local pending_csrs
  pending_csrs=$(oc get csr --no-headers 2>/dev/null | grep "Pending" || true)

  if [[ -z "$pending_csrs" ]]; then
    pass "No pending CSRs found."
  else
    local csr_count; csr_count=$(echo "$pending_csrs" | wc -l | tr -d ' ')
    printf "  ${C_YELLOW}${C_BOLD}%-50s %-22s %-10s %-12s${C_RESET}\n" "CSR NAME" "REQUESTOR" "AGE" "STATUS"
    col_sep
    while read -r name _age requestor condition; do
      printf "  ${C_YELLOW}%-50s %-22s %-10s %-12s${C_RESET}\n" "$name" "$requestor" "$_age" "$condition"
    done <<< "$pending_csrs"
    echo; warn "${csr_count} pending CSR(s) require approval"
    echo
    div_light; printf "${C_YELLOW}  CSR Approval${C_RESET}\n"; div_light
    guide "oc get csr"
    guide "oc adm certificate approve <csr-name>"
    guide "oc get csr -o name | xargs oc adm certificate approve"
    note "Monitor during upgrade: watch oc get csr"
    echo
    mark_warn "Pending CSRs require approval"
  fi
}

# ==============================================================================
# [15] CRITICAL PROMETHEUS ALERTS
# ==============================================================================
check_critical_alerts() {
  section_header 15 "Critical & Firing Prometheus Alerts"
  ((CHECKS_RUN++))
  info "Querying Prometheus for active alerts (critical + warning)"
  note "Target: zero critical alerts before upgrading"
  echo

  local prom_pod
  prom_pod=$(oc -n openshift-monitoring get pod \
    -l app.kubernetes.io/name=prometheus,prometheus=k8s \
    --field-selector=status.phase=Running \
    -o name 2>/dev/null | head -n1 | cut -d/ -f2)

  if [[ -z "$prom_pod" ]]; then
    warn "Prometheus pod not found — skipping alert check"
    mark_warn "Prometheus unavailable for alert check"; return
  fi

  local alert_json
  alert_json=$(oc -n openshift-monitoring exec -c prometheus "$prom_pod" -- \
    curl -s -G 'http://localhost:9090/api/v1/alerts' 2>/dev/null)

  if [[ -z "$alert_json" ]]; then
    warn "Could not retrieve alerts from Prometheus API"
    mark_warn "Prometheus alert query failed"; return
  fi

  local critical_alerts warning_alerts
  critical_alerts=$(echo "$alert_json" | jq -r '
    .data.alerts[] | select(.state=="firing") | select(.labels.severity=="critical") |
    select(.labels.alertname != "Watchdog") |
    "CRITICAL|" + .labels.alertname + "|" + (.labels.namespace // "cluster") +
    "|" + (.annotations.summary // "N/A")' 2>/dev/null || true)

  warning_alerts=$(echo "$alert_json" | jq -r '
    .data.alerts[] | select(.state=="firing") | select(.labels.severity=="warning") |
    select(.labels.alertname != "Watchdog") |
    "WARNING|" + .labels.alertname + "|" + (.labels.namespace // "cluster") +
    "|" + (.annotations.summary // "N/A")' 2>/dev/null || true)

  local crit_count=0 warn_count=0
  [[ -n "$critical_alerts" ]] && crit_count=$(echo "$critical_alerts" | wc -l | tr -d ' ')
  [[ -n "$warning_alerts"  ]] && warn_count=$(echo "$warning_alerts"  | wc -l | tr -d ' ')

  if [[ "$crit_count" -gt 0 ]]; then
    printf "  ${C_RED}${C_BOLD}%-10s %-45s %-25s %-50s${C_RESET}\n" "SEVERITY" "ALERTNAME" "NAMESPACE" "SUMMARY"
    col_sep
    while IFS='|' read -r sev alert ns summary; do
      printf "  ${C_RED}%-10s %-45s %-25s %-50s${C_RESET}\n" "${sev// /}" "${alert// /}" "${ns// /}" "${summary:0:49}"
    done <<< "$critical_alerts"
    echo
    fail "CRITICAL alerts firing: ${crit_count} — DO NOT UPGRADE until resolved"
    mark_fail "Critical alerts firing: $crit_count"
  else
    pass "No critical alerts firing."
  fi

  echo
  if [[ "$warn_count" -gt 0 ]]; then
    printf "  ${C_YELLOW}${C_BOLD}%-10s %-45s %-25s %-50s${C_RESET}\n" "SEVERITY" "ALERTNAME" "NAMESPACE" "SUMMARY"
    col_sep
    while IFS='|' read -r sev alert ns summary; do
      printf "  ${C_YELLOW}%-10s %-45s %-25s %-50s${C_RESET}\n" "${sev// /}" "${alert// /}" "${ns// /}" "${summary:0:49}"
    done <<< "$warning_alerts"
    echo
    warn "${warn_count} warning alert(s) firing — review before upgrading"
    mark_warn "Warning alerts firing: $warn_count"
  else
    pass "No warning alerts firing."
  fi
}

# ==============================================================================
# [16] WORKLOAD HEALTH
# ==============================================================================
check_workloads() {
  section_header 16 "Workload Health (Pods, Deployments, StatefulSets)"
  ((CHECKS_RUN++))

  local ART_UNHEALTHY="${ARTIFACT_DIR}/unhealthy-pods.txt"
  local ART_REPLICAS="${ARTIFACT_DIR}/replica-mismatches.txt"
  local ART_POD_STATUS="${ARTIFACT_DIR}/pod-status-grouped.txt"
  local ART_PODS_WIDE="${ARTIFACT_DIR}/oc-get-pods-wide.txt"

  for f_var in "$ART_UNHEALTHY" "$ART_REPLICAS" "$ART_POD_STATUS"; do
    { printf "# OCP Health Check — %s\n# Generated: %s\n# Cluster: %s\n\n" \
        "$(basename "$f_var" .txt)" "$(date)" "$(oc whoami --show-server 2>/dev/null)"; } > "$f_var"
  done

  info "Writing full pod dump to artifact..."
  { printf "# oc get pods -A -o wide\n# Generated: %s\n\n" "$(date)"
    oc get pods -A -o wide 2>/dev/null; } > "$ART_PODS_WIDE"
  artifact_note "$ART_PODS_WIDE"
  echo

  info "Unhealthy pods (not Running/Succeeded):"
  echo
  local all_pods_json unhealthy_pods
  all_pods_json=$(oc get pods -A -o json 2>/dev/null)
  unhealthy_pods=$(echo "$all_pods_json" | jq -r '
    .items[] |
    select(.status.phase != "Succeeded" and
      (.status.phase != "Running" or any(.status.containerStatuses[]?; .ready == false))) |
    "\(.metadata.namespace)|\(.metadata.name)|\(.status.phase)|" +
    "\(.status.containerStatuses[0].state.waiting.reason //
       .status.containerStatuses[0].state.terminated.reason // "NotReady")|" +
    "\(.status.hostIP // "N/A")"')

  if [[ -n "$unhealthy_pods" ]]; then
    printf "  ${C_YELLOW}${C_BOLD}%-38s %-38s %-16s %-20s %-16s${C_RESET}\n" \
      "NAMESPACE" "POD" "PHASE" "REASON" "NODE IP"
    col_sep
    echo "$unhealthy_pods" | head -n 20 | while IFS='|' read -r ns pod phase reason hostip; do
      printf "  ${C_YELLOW}%-38s %-38s %-16s %-20s %-16s${C_RESET}\n" "$ns" "$pod" "$phase" "$reason" "$hostip"
    done
    local total_unhealthy; total_unhealthy=$(echo "$unhealthy_pods" | wc -l | tr -d ' ')
    [[ "$total_unhealthy" -gt 20 ]] && note "Showing 20 of $total_unhealthy — see artifact for full list"
    { printf "%-38s %-38s %-16s %-20s %-16s\n" "NAMESPACE" "POD" "PHASE" "REASON" "NODE IP"
      echo "$unhealthy_pods" | while IFS='|' read -r ns pod phase reason hostip; do
        printf "%-38s %-38s %-16s %-20s %-16s\n" "$ns" "$pod" "$phase" "$reason" "$hostip"; done
    } >> "$ART_UNHEALTHY"
    artifact_note "$ART_UNHEALTHY  (${total_unhealthy} pods)"
    echo; warn "${total_unhealthy} unhealthy pod(s) detected"; mark_warn "Unhealthy pods detected"
  else
    pass "No unhealthy pods detected."
  fi
  echo

  info "Deployments / StatefulSets with replica mismatches:"
  echo
  local ds_data ds_warn=0
  ds_data=$(oc get deploy,statefulset -A --no-headers 2>/dev/null)
  while read -r ns name ready _up_to_date available _age; do
    IFS='/' read -r actual desired <<< "$ready"
    if [[ "${actual:-0}" != "${desired:-0}" ]]; then
      printf "  ${C_YELLOW}  %-38s / %-38s  Ready: %s  Desired: %s${C_RESET}\n" \
        "$ns" "$name" "$actual" "$desired"
      printf "%-10s %-38s %-38s %-10s %-10s\n" "deploy/sts" "$ns" "$name" "$desired" "$actual" >> "$ART_REPLICAS"
      ((ds_warn++))
    fi
  done <<< "$ds_data"
  if [[ "$ds_warn" -gt 0 ]]; then
    echo; artifact_note "$ART_REPLICAS  (${ds_warn} mismatch(es))"
    warn "Replica mismatches on ${ds_warn} resource(s)"; mark_warn "Replica mismatches detected"
  else
    pass "All Deployments/StatefulSets have matching replicas."
  fi
  echo

  info "Pod health by namespace (excl. openshift* / kube*):"
  echo
  printf "  ${C_CYAN}${C_BOLD}%-40s %-10s %-12s %-10s${C_RESET}\n" "NAMESPACE" "TOTAL" "HEALTHY" "UNHEALTHY"
  col_sep
  local pod_warn=0
  while read -r ns; do
    local total healthy not_healthy
    total=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
    healthy=$(oc get pods -n "$ns" -o json 2>/dev/null | jq '[
      .items[] | select(
        (.status.phase=="Running" and all(.status.containerStatuses[]?; .ready==true)) or
        (.status.phase=="Succeeded")
      )
    ] | length')
    not_healthy=$(( total - healthy ))
    local color="${C_GREEN}"; [[ "$not_healthy" -gt 0 ]] && { color="${C_YELLOW}"; pod_warn=1; }
    printf "  ${color}%-40s %-10s %-12s %-10s${C_RESET}\n" "$ns" "$total" "$healthy" "$not_healthy"
    printf "%-40s %-10s %-10s %-10s\n" "$ns" "$total" "$healthy" "$not_healthy" >> "$ART_POD_STATUS"
  done < <(oc get namespace -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
           grep -Ev "$EXCLUDE_NS_REGEX")
  artifact_note "$ART_POD_STATUS"
  [[ "$pod_warn" -eq 1 ]] && mark_warn "Unhealthy pods in application namespaces"
}

# ==============================================================================
# [17] PDB ANALYSIS
# ==============================================================================
check_pdb() {
  section_header 17 "Pod Disruption Budget Analysis"
  ((CHECKS_RUN++))
  note "Disruptions Allowed = pods that can be taken down without violating the PDB"
  echo

  local tmp_json; tmp_json=$(mktemp)
  oc get pdb -A -o json 2>/dev/null > "$tmp_json"

  local table
  table=$(jq -r '
    .items[] | select(.metadata.namespace | test("^openshift") | not) |
    {ns:.metadata.namespace,name:.metadata.name,expected:.status.expectedPods,
     healthy:.status.currentHealthy,minAvailable:.spec.minAvailable,
     maxUnavailable:.spec.maxUnavailable} as $p |
    (if $p.minAvailable!=null then {type:"minAvailable",calc:($p.healthy-$p.minAvailable)}
     elif $p.maxUnavailable!=null then {type:"maxUnavailable",calc:($p.maxUnavailable-($p.expected-$p.healthy))}
     else {type:"none",calc:0} end) as $r |
    ($r.calc|if .<0 then 0 else . end) as $da |
    ($p.expected|if .==0 then 0 else (($da/.)*100+0.5|floor) end) as $pct |
    (if $da==0 then "RED" elif $pct==100 then "BLUE" elif $pct<30 then "ORANGE" else "GREEN" end) as $c |
    "\($c)|\($p.ns)|\($p.name)|\($r.type)|\($p.expected)|\($p.healthy)|\($da)|\($pct)%"
  ' "$tmp_json" 2>/dev/null)

  printf "  ${C_CYAN}${C_BOLD}%-36s %-30s %-14s %-8s %-8s %-12s %-8s${C_RESET}\n" \
    "NAMESPACE" "PDB NAME" "TYPE" "EXPECTED" "HEALTHY" "DISRUPTIONS" "DISRUPT%"
  col_sep

  local blocked=0 full_outage=0 safe=0 low_ha=0 total=0
  while IFS='|' read -r color ns name type exp healthy da pct; do
    local c
    case "$color" in RED) c="${C_RED}";((blocked++));; BLUE) c="${C_BLUE}";((full_outage++));;
      ORANGE) c="${C_ORANGE}";((low_ha++));; GREEN) c="${C_GREEN}";((safe++));; *) c="${C_WHITE}";; esac
    ((total++))
    printf "  ${c}%-36s %-30s %-14s %-8s %-8s %-12s %-8s${C_RESET}\n" \
      "$ns" "$name" "$type" "$exp" "$healthy" "$da" "$pct"
  done <<< "$table"
  echo

  [[ "$full_outage" -gt 0 ]] && \
    warn "${full_outage} PDB(s) allow 100% disruption — full service outage possible during upgrade"
  echo
  printf "${C_BOLD}  PDB Summary${C_RESET}\n"; div_light
  printf "  ${C_RED}  Blocked (0 disruptions)   : %d${C_RESET}\n" "$blocked"
  printf "  ${C_ORANGE}  Low HA (< 30%%)            : %d${C_RESET}\n" "$low_ha"
  printf "  ${C_GREEN}  Safe for maintenance       : %d${C_RESET}\n" "$safe"
  printf "  ${C_BLUE}  Full outage allowed (100%%) : %d${C_RESET}\n" "$full_outage"
  printf "  ${C_WHITE}  Total analyzed             : %d${C_RESET}\n" "$total"
  div_light
  [[ "$blocked" -gt 0 ]] && { echo; fail "PDB(s) blocking all disruptions — upgrade will stall"; mark_fail "PDB blocking upgrade"; }
  rm -f "$tmp_json"
}

# ==============================================================================
# [18] PVC / PV HEALTH
# ==============================================================================
check_pvc() {
  section_header 18 "PV & PVC Health"
  ((CHECKS_RUN++))

  local pvc_json; pvc_json=$(oc get pvc -A -o json 2>/dev/null)

  info "Non-Bound PVCs:"
  echo
  local non_bound
  non_bound=$(echo "$pvc_json" | jq -r '
    .items[] | select(.status.phase != "Bound") |
    "\(.metadata.namespace)|\(.metadata.name)|\(.status.phase)|" +
    "\(.spec.resources.requests.storage // "N/A")|\(.spec.storageClassName // "N/A")"' || true)
  if [[ -n "$non_bound" ]]; then
    printf "  ${C_YELLOW}${C_BOLD}%-34s %-34s %-14s %-12s %-20s${C_RESET}\n" \
      "NAMESPACE" "PVC NAME" "STATUS" "CAPACITY" "STORAGECLASS"
    col_sep
    while IFS='|' read -r ns name status cap sc; do
      printf "  ${C_YELLOW}%-34s %-34s %-14s %-12s %-20s${C_RESET}\n" "$ns" "$name" "$status" "$cap" "$sc"
    done <<< "$non_bound"
    echo; warn "$(echo "$non_bound" | wc -l | tr -d ' ') PVC(s) not in Bound state"; mark_warn "Non-Bound PVCs"
  else
    pass "All PVCs are Bound."
  fi
  echo

  info "PVCs stuck in Terminating:"
  echo
  local terminating
  terminating=$(echo "$pvc_json" | jq -r '
    .items[] | select(.metadata.deletionTimestamp != null) |
    "\(.metadata.namespace)|\(.metadata.name)|\(.metadata.deletionTimestamp)"' || true)
  if [[ -n "$terminating" ]]; then
    printf "  ${C_RED}${C_BOLD}%-34s %-34s %-25s${C_RESET}\n" "NAMESPACE" "PVC NAME" "DELETION TIMESTAMP"
    col_sep
    while IFS='|' read -r ns name ts; do
      printf "  ${C_RED}%-34s %-34s %-25s${C_RESET}\n" "$ns" "$name" "$ts"
    done <<< "$terminating"
    echo; warn "PVCs stuck in Terminating"; mark_warn "PVCs in Terminating state"
  else
    pass "No PVCs stuck in Terminating."
  fi
  echo

  info "PV Status Summary:"
  echo
  printf "  ${C_CYAN}${C_BOLD}%-44s %-12s %-12s %-26s %-20s${C_RESET}\n" \
    "PV NAME" "CAPACITY" "STATUS" "CLAIM" "STORAGECLASS"
  col_sep
  oc get pv -o json 2>/dev/null | jq -r '
    .items[] |
    "\(.metadata.name)|\(.spec.capacity.storage // "N/A")|\(.status.phase)|" +
    "\(if .spec.claimRef then "\(.spec.claimRef.namespace)/\(.spec.claimRef.name)" else "N/A" end)|" +
    "\(.spec.storageClassName // "N/A")"' | while IFS='|' read -r pv cap phase claim sc; do
    local color="${C_GREEN}"
    [[ "$phase" != "Bound" && "$phase" != "Available" ]] && color="${C_YELLOW}"
    printf "  ${color}%-44s %-12s %-12s %-26s %-20s${C_RESET}\n" "$pv" "$cap" "$phase" "${claim:0:25}" "$sc"
  done
}

# ==============================================================================
# [19] NODE DISK USAGE
# ==============================================================================
check_disk_sysroot() {
  section_header 19 "Node Container Runtime Disk Usage"
  ((CHECKS_RUN++))
  note "Threshold: ${DISK_WARN_THRESHOLD}%  —  this check may take a few minutes"
  echo
  printf "  ${C_CYAN}${C_BOLD}%-44s %-10s %-10s %-10s %-8s %-20s${C_RESET}\n" \
    "NODE" "SIZE" "USED" "AVAIL" "USE%" "MOUNT"
  col_sep

  for role_label in "node-role.kubernetes.io/master=" "node-role.kubernetes.io/infra=" "node-role.kubernetes.io/worker="; do
    local role="${role_label%%=*}"; role="${role##*/}"
    local nodes; nodes=$(oc get nodes -l "$role_label" -o name 2>/dev/null | awk -F'/' '{print $2}')
    [[ -z "$nodes" ]] && continue
    printf "\n  ${C_BLUE}  Role: %s${C_RESET}\n" "$(echo "$role" | tr '[:lower:]' '[:upper:]')"

    for node in $nodes; do
      local output
      output=$(timeout 30s oc debug node/"$node" --quiet -- bash -c '
        for path in /host/var/lib/containers /host/var/lib/containerd /host; do
          [ -d "$path" ] && df -h "$path" | tail -n1 && break
        done' 2>/dev/null)
      if [[ -z "$output" ]]; then
        printf "  ${C_RED}  %-44s  debug timed out or failed${C_RESET}\n" "$node"; continue
      fi
      read -r _fs size used avail use_pct mount <<< "$output"
      local pct_num="${use_pct//%/}" color="${C_GREEN}"
      compare_gt "${pct_num:-0}" "$DISK_WARN_THRESHOLD" && {
        color="${C_RED}"; mark_warn "High disk usage on $node ($use_pct)"; }
      printf "  ${color}%-44s %-10s %-10s %-10s %-8s %-20s${C_RESET}\n" \
        "$node" "$size" "$used" "$avail" "$use_pct" "$mount"
    done
  done
  echo
}

# ==============================================================================
# [20] EVENTS
# ==============================================================================
check_events() {
  section_header 20 "Recent Warning Events (last 25)"
  ((CHECKS_RUN++))
  info "Non-Normal events sorted by lastTimestamp"
  echo
  printf "  ${C_CYAN}${C_BOLD}%-22s %-10s %-30s %-28s %-40s${C_RESET}\n" \
    "NAMESPACE" "TYPE" "REASON" "OBJECT" "MESSAGE"
  col_sep
  oc get events -A --sort-by='.lastTimestamp' 2>/dev/null | \
  grep -v "Normal" | tail -n 25 | \
  while read -r ns _s1 _s2 type reason obj _from msg; do
    printf "  ${C_YELLOW}%-22s %-10s %-30s %-28s %-40s${C_RESET}\n" \
      "$ns" "$type" "$reason" "$obj" "${msg:0:39}"
  done
  echo
}

# ==============================================================================
# [21] ROUTE HEALTH
# ==============================================================================
check_routes() {
  section_header 21 "Application Route Health (HTTP Probe)"
  ((CHECKS_RUN++))
  info "Probing routes in non-openshift/kube namespaces..."
  echo
  printf "  ${C_CYAN}${C_BOLD}%-35s %-40s %-10s %-10s${C_RESET}\n" "NAMESPACE" "ROUTE" "HTTP" "TIME(s)"
  col_sep

  local route_warn=0
  while IFS='|' read -r ns route host; do
    [[ -z "$host" ]] && continue
    local proto="http"
    oc get route "$route" -n "$ns" -o jsonpath='{.spec.tls.termination}' 2>/dev/null | grep -q . && proto="https"
    local result status_code time_total color
    result=$(curl -k -L -s -o /dev/null --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" -w "%{http_code}|%{time_total}" "$proto://$host" 2>/dev/null || printf "000|0")
    status_code="${result%%|*}"; time_total="${result##*|}"
    color="${C_GREEN}"; [[ ! "$status_code" =~ ^[23] ]] && { color="${C_RED}"; route_warn=1; }
    printf "  ${color}%-35s %-40s %-10s %-10s${C_RESET}\n" "$ns" "$route" "$status_code" "$time_total"
  done < <(oc get route --all-namespaces 2>/dev/null \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.host}{"\n"}{end}' | \
    grep -Ev "^($EXCLUDE_NS_REGEX)")
  echo
  [[ "$route_warn" -eq 1 ]] && { warn "One or more routes returned non-2xx/3xx"; mark_warn "Route health failures"; }
  [[ "$route_warn" -eq 0 ]] && pass "All probed routes returned healthy HTTP status codes."
}

# ==============================================================================
# [22] EGRESSIP
# ==============================================================================
check_egressip() {
  section_header 22 "EgressIP Health & Assignment"
  ((CHECKS_RUN++))

  info "Egress-assignable nodes:"
  echo
  oc get nodes -l k8s.ovn.org/egress-assignable='' \
    -o 'custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address,READY:.status.conditions[?(@.type=="Ready")].status' \
    --no-headers 2>/dev/null || printf "  ${C_YELLOW}  No egress-assignable nodes found.${C_RESET}\n"
  echo

  info "EgressIP Resources:"
  echo
  oc get egressips -A \
    -o custom-columns=NAME:.metadata.name,IP:.status.items[*].egressIP,NODE:.status.items[*].node \
    --no-headers 2>/dev/null || printf "  ${C_YELLOW}  No EgressIP resources found.${C_RESET}\n"
  echo

  info "Duplicate EgressIP Check:"
  local dupes
  dupes=$(oc get egressips -A \
    -o jsonpath='{range .items[*]}{.status.items[*].egressIP}{"\n"}{end}' 2>/dev/null | sort | uniq -d)
  if [[ -n "$dupes" ]]; then
    fail "Duplicate EgressIPs: $dupes"; mark_warn "Duplicate EgressIPs"
  else
    pass "No duplicate EgressIPs."
  fi
  echo

  info "Unassigned EgressIP Check:"
  local unassigned
  unassigned=$(oc get egressips -o 'custom-columns=NAME:.metadata.name,ASSIGNED:.status.items[*].egressIP' \
    --no-headers 2>/dev/null | awk '$2=="" || $2=="<none>" {print $1 " has no assigned IP/Node"}')
  if [[ -n "$unassigned" ]]; then
    while read -r line; do warn "$line"; done <<< "$unassigned"; mark_warn "Unassigned EgressIPs"
  else
    pass "All EgressIPs are assigned."
  fi
  echo
}

# ==============================================================================
# [23] HARDWARE COMPATIBILITY  [NEW]
# ==============================================================================
check_hw_compat() {
  section_header 23 "Hardware & Hypervisor Compatibility"
  ((CHECKS_RUN++))
  info "Detecting platform and infrastructure type..."
  echo

  local infra_json platform_type cloud_name
  infra_json=$(oc get infrastructure cluster -o json 2>/dev/null || true)
  if [[ -z "$infra_json" ]]; then
    warn "Unable to query Infrastructure object — manual verification required."
    mark_warn "Cannot determine platform type"; return
  fi

  platform_type=$(echo "$infra_json" | jq -r '.spec.platformSpec.type // .status.platform // "Unknown"')
  cloud_name=$(echo "$infra_json"    | jq -r '.status.infrastructureName // "N/A"')

  printf "  ${C_WHITE}%-22s${C_RESET} %s\n" "Platform Type"  "$platform_type"
  printf "  ${C_WHITE}%-22s${C_RESET} %s\n" "Infrastructure" "$cloud_name"
  echo

  case "$(echo "$platform_type" | tr '[:upper:]' '[:lower:]')" in
    vsphere|vmware)
      warn "VMware/vSphere environment detected — verify hypervisor compatibility"
      echo
      div_light; printf "${C_YELLOW}  VMware Compatibility Checklist${C_RESET}\n"; div_light
      note "Verify vSphere / vCenter version is supported for the target OCP release."
      note "Reference: https://access.redhat.com/articles/4164401"
      note "Check VMware CSI driver compatibility with the target OCP version."
      note "Ensure NSX-T (if in use) is on a supported version."
      mark_warn "VMware environment — verify hypervisor compatibility before upgrade"
      ;;
    nutanix)
      warn "Nutanix environment detected — verify AOS and Prism Central compatibility"
      echo
      div_light; printf "${C_YELLOW}  Nutanix Compatibility Checklist${C_RESET}\n"; div_light
      note "Verify AOS and Prism Central versions are supported for the target OCP release."
      note "Reference: https://portal.nutanix.com/page/documents/compatibility-interoperability-matrix"
      note "Confirm Nutanix CSI driver version is compatible with target OCP version."
      mark_warn "Nutanix environment — verify AOS and Prism Central compatibility"
      ;;
    aws)
      info "AWS platform detected."
      note "Verify EC2 instance types are supported for the target OCP release."
      ;;
    azure)
      info "Azure platform detected."
      note "Verify Azure VM SKUs and regions are supported for the target OCP release."
      ;;
    gcp)
      info "GCP platform detected."
      note "Verify GCP machine types are supported for the target OCP release."
      ;;
    baremetal|none)
      info "Bare metal / on-premises platform detected."
      note "Verify firmware (BIOS/UEFI/BMC) is up to date."
      note "Confirm BMC/IPMI access is available for node recovery if needed."
      ;;
    *)
      warn "Platform '$platform_type' — manual hardware compatibility review required."
      note "Reference: https://access.redhat.com/articles/4128421"
      mark_warn "Unknown platform — verify hardware compatibility manually"
      ;;
  esac

  echo
  div_light; printf "${C_YELLOW}  General Pre-upgrade Hardware Reminders${C_RESET}\n"; div_light
  note "Confirm target OCP version is supported on your current hypervisor/hardware."
  note "Ensure all node firmware (BMC/UEFI/drivers) is at a supported version."
  note "Verify enough node capacity to handle the rolling upgrade drain."
  note "Review hardware-specific release notes: https://access.redhat.com/errata/"
  echo
  pass "Hardware compatibility reminder check complete — review notes above."
}

# ==============================================================================
# [24] CLOUD CREDENTIAL OPERATOR  [NEW]
# ==============================================================================
check_cloud_creds() {
  section_header 24 "Cloud Credential Operator (CCO) Compatibility"
  ((CHECKS_RUN++))
  info "Detecting Cloud Credential Operator mode..."
  echo

  local cco_mode
  cco_mode=$(oc get cloudcredentials cluster -o=jsonpath='{.spec.credentialsMode}' 2>/dev/null || echo "")

  if [[ -z "$cco_mode" ]]; then
    cco_mode="Mint (default — not explicitly set)"
    note "credentialsMode not explicitly configured — defaulting to Mint mode."
  fi

  printf "  ${C_WHITE}%-22s${C_RESET} %s\n" "CCO Mode" "$cco_mode"
  echo

  case "$(echo "$cco_mode" | tr '[:upper:]' '[:lower:]')" in
    mint*|"mint (default"*)
      pass "CCO Mode: Mint — credentials are managed automatically."
      echo
      info "Mint mode upgrade notes:"
      note "Verify root cloud credential has sufficient permissions for the target version."
      note "CCO will automatically create/update credentials during upgrade."
      guide "oc get credentialsrequests -A -o wide"
      ;;
    manual*)
      warn "CCO Mode: Manual — credential manifests must be updated before upgrade"
      echo
      div_light; printf "${C_YELLOW}  Manual Mode — Required Steps${C_RESET}\n"; div_light
      note "1. Extract CredentialsRequests for the target OCP version."
      note "2. Generate updated policy manifests using ccoctl."
      note "3. Apply updated secrets before starting the upgrade."
      echo
      guide 'RELEASE_IMAGE=$(oc get clusterversion version -o jsonpath='"'"'{.status.desired.image}'"'"')'
      guide 'oc adm release extract --credentials-requests --cloud=<aws|azure|gcp> \'
      guide '  --to=./credrequests $RELEASE_IMAGE'
      guide 'ccoctl <aws|azure|gcp> create-all --name=<cluster> \'
      guide '  --credentials-requests-dir=./credrequests --output-dir=./output'
      guide 'oc apply -f ./output/manifests/'
      echo
      note "Reference: https://docs.openshift.com/container-platform/latest/authentication/managing_cloud_provider_credentials/cco-mode-manual.html"
      mark_warn "CCO Manual mode — credential manifests must be updated before upgrade"
      ;;
    passthrough*)
      info "CCO Mode: Passthrough — credentials passed through as-is."
      note "Verify cloud credentials have all required permissions for the target version."
      ;;
    *)
      warn "CCO Mode unrecognised or could not be determined: '$cco_mode'"
      note "Check: oc get cloudcredentials cluster -o yaml"
      mark_warn "CCO mode could not be determined"
      ;;
  esac

  echo
  info "CredentialsRequests (first 15):"
  oc get credentialsrequests -A --no-headers 2>/dev/null | head -n 15 | \
    while read -r ns name rest; do
      printf "  ${C_WHITE}  %-40s %-30s${C_RESET}\n" "$ns" "$name"
    done || note "No CredentialsRequests found or CCO not in use."
  echo
  pass "CCO check complete."
}

# ==============================================================================
# [25] THIRD-PARTY CSI DRIVER COMPATIBILITY  [NEW]
# ==============================================================================
check_csi_compat() {
  section_header 25 "Third-party CSI Driver Compatibility"
  ((CHECKS_RUN++))
  info "Scanning for installed CSI drivers..."
  echo

  local csi_drivers
  csi_drivers=$(oc get csidrivers -o json 2>/dev/null)
  if [[ -z "$csi_drivers" ]]; then
    warn "Unable to query CSI drivers — manual verification required."
    mark_warn "Cannot query CSI drivers"; return
  fi

  local driver_count
  driver_count=$(echo "$csi_drivers" | jq -r '.items | length')

  printf "  ${C_CYAN}${C_BOLD}%-55s %-20s${C_RESET}\n" "CSI DRIVER" "TYPE"
  col_sep

  local third_party_found=false
  echo "$csi_drivers" | jq -r '.items[].metadata.name' | sort | while read -r driver; do
    local dtype="Built-in" color="${C_GREEN}"
    case "$driver" in
      *netapp*|*trident*|*ontap*)  dtype="NetApp Trident"; color="${C_YELLOW}"; third_party_found=true ;;
      *dell*|*powerstore*|*unity*|*isilon*|*vxflexos*|*powermax*) dtype="Dell CSI"; color="${C_YELLOW}"; third_party_found=true ;;
      *nutanix*)                   dtype="Nutanix CSI";   color="${C_YELLOW}"; third_party_found=true ;;
      *rook*|*ceph*)               dtype="Rook/Ceph";     color="${C_YELLOW}"; third_party_found=true ;;
      *portworx*|*px*)             dtype="Portworx";      color="${C_YELLOW}"; third_party_found=true ;;
      *pure*|*flasharray*|*flashblade*) dtype="Pure Storage"; color="${C_YELLOW}"; third_party_found=true ;;
      *hpe*|*nimble*|*primera*)    dtype="HPE CSI";       color="${C_YELLOW}"; third_party_found=true ;;
      *ibm*)                       dtype="IBM CSI";       color="${C_YELLOW}"; third_party_found=true ;;
      *vsphere*|*vmware*)          dtype="VMware vSphere"; color="${C_YELLOW}"; third_party_found=true ;;
      *gcepd*|*.gke.*|*filestore*) dtype="GCP";           color="${C_GREEN}" ;;
      *ebs*|*efs*|*fsx*|*.aws.*|*amazonaws*) dtype="AWS"; color="${C_GREEN}" ;;
      *disk.csi*|*file.csi*|*.azure.*) dtype="Azure";    color="${C_GREEN}" ;;
      *) echo "$driver" | grep -qE "^(csi\.ovirt|csi\.openshift|kubernetes\.io)" || \
           { dtype="Third-party"; color="${C_YELLOW}"; third_party_found=true; } ;;
    esac
    printf "  ${color}%-55s %-20s${C_RESET}\n" "$driver" "$dtype"
  done
  echo
  note "$driver_count CSI driver(s) detected."
  echo

  if echo "$csi_drivers" | jq -r '.items[].metadata.name' | grep -qiE \
      "netapp|trident|dell|powerstore|unity|isilon|nutanix|portworx|pure|hpe|nimble|vsphere|vmware|rook|ceph|ibm"; then
    div_light
    printf "${C_YELLOW}  Third-party CSI Driver Compatibility Reminders${C_RESET}\n"
    div_light
    echo "$csi_drivers" | jq -r '.items[].metadata.name' | grep -qi "netapp\|trident" && {
      warn "NetApp Trident detected — verify CSI version compatibility"
      note "Reference: https://docs.netapp.com/us-en/trident/trident-rn.html"
      guide "oc get tridentorchestrator -n trident -o wide"; }
    echo "$csi_drivers" | jq -r '.items[].metadata.name' | grep -qi "dell\|powerstore\|isilon\|unity" && {
      warn "Dell CSI driver detected — verify version compatibility"
      note "Reference: https://dell.github.io/csm-docs/docs/csidriver/release/"; }
    echo "$csi_drivers" | jq -r '.items[].metadata.name' | grep -qi "nutanix" && {
      warn "Nutanix CSI driver detected — verify version compatibility"
      note "Reference: https://portal.nutanix.com/page/documents/list?type=software&filterKey=software&filterVal=CSI"; }
    echo "$csi_drivers" | jq -r '.items[].metadata.name' | grep -qi "vsphere\|vmware" && {
      warn "VMware vSphere CSI driver detected — verify version compatibility"
      note "Reference: https://docs.vmware.com/en/VMware-vSphere-Container-Storage-Plug-in/index.html"; }
    echo
    note "Before upgrading: check each CSI driver's support matrix for the target OCP version."
    note "Upgrade the driver first if required, then validate PVC access before proceeding."
    echo
    mark_warn "Third-party CSI drivers detected — verify compatibility before upgrade"
  else
    pass "No third-party CSI drivers requiring manual compatibility checks."
  fi

  info "StorageClasses:"
  echo
  oc get storageclass --no-headers 2>/dev/null | \
    while read -r name provisioner reclaim _binding _vol _rest; do
      local color="${C_WHITE}"
      echo "$provisioner" | grep -qiE "openshift|kubernetes.io|ebs|efs|gce|disk.csi|file.csi|azure" && \
        color="${C_GREEN}" || color="${C_YELLOW}"
      printf "  ${color}%-35s %-52s %-12s${C_RESET}\n" "$name" "$provisioner" "$reclaim"
    done
  echo
  pass "CSI driver compatibility check complete — review notes above."
}

# ==============================================================================
# FINAL SUMMARY
# ==============================================================================
print_summary() {
  echo
  div_heavy
  printf "${C_CYAN}${C_BOLD}  CHECK SUMMARY${C_RESET}\n"
  div_heavy
  echo
  printf "  ${C_WHITE}%-20s${C_RESET} %d\n"     "Checks Run"      "$CHECKS_RUN"
  printf "  ${C_MAGENTA}%-20s${C_RESET} %d\n"   "Checks Skipped"  "$CHECKS_SKIPPED"
  printf "  ${C_YELLOW}%-20s${C_RESET} %d\n"    "Warnings"        "$WARN_COUNT"
  printf "  ${C_RED}%-20s${C_RESET} %d\n"       "Failures"        "$FAIL_COUNT"
  printf "  ${C_MAGENTA}%-20s${C_RESET} %s\n"   "Artifacts"       "$ARTIFACT_DIR"
  echo

  if [[ "$WARN_COUNT" -gt 0 ]]; then
    div_light; printf "${C_YELLOW}${C_BOLD}  Warnings${C_RESET}\n"; div_light
    for w in "${WARN_ITEMS[@]}"; do printf "  ${C_YELLOW}  %s${C_RESET}\n" "$w"; done; echo
  fi

  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    div_light; printf "${C_RED}${C_BOLD}  Failures${C_RESET}\n"; div_light
    for f in "${FAIL_ITEMS[@]}"; do printf "  ${C_RED}  %s${C_RESET}\n" "$f"; done; echo
  fi

  div_heavy
  if [[ "$EXIT_CODE" -eq 0 ]]; then
    printf "${C_GREEN}${C_BOLD}  RESULT: PASS — Cluster appears ready for upgrade${C_RESET}\n"
  elif [[ "$EXIT_CODE" -eq 1 ]]; then
    printf "${C_YELLOW}${C_BOLD}  RESULT: WARNING — Review warnings before upgrading${C_RESET}\n"
  else
    printf "${C_RED}${C_BOLD}  RESULT: FAILED — Resolve critical issues before upgrading${C_RESET}\n"
  fi
  div_heavy

  if [[ -d "$ARTIFACT_DIR" ]]; then
    echo; printf "${C_MAGENTA}${C_BOLD}  Artifact Files Generated:${C_RESET}\n"
    while IFS= read -r f; do
      local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1)
      printf "  ${C_MAGENTA}  %-60s (%s)${C_RESET}\n" "$f" "$sz"
    done < <(find "$ARTIFACT_DIR" -type f | sort)
  fi
  echo
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
  prereq_check
  print_header

  [[ "$RUN_CLUSTER_VERSION"      == "true" ]] && check_cluster_version      || skipped_section 1  "Cluster Version & Upgrade Status"
  [[ "$RUN_CLUSTER_OPERATORS"    == "true" ]] && check_cluster_operators    || skipped_section 2  "Cluster Operators Health"
  [[ "$RUN_OLM_OPERATORS"        == "true" ]] && check_olm_operators        || skipped_section 3  "OLM Operators (CSV)"
  [[ "$RUN_NODE_STATUS"          == "true" ]] && check_node_status          || skipped_section 4  "Node Status"
  [[ "$RUN_NODE_RESOURCES"       == "true" ]] && check_node_resources       || skipped_section 5  "Node CPU & Memory Usage"
  [[ "$RUN_MCP_STATUS"           == "true" ]] && check_mcp_status           || skipped_section 6  "MCP Status + MC Match"
  [[ "$RUN_CONTROL_PLANE_LABELS" == "true" ]] && check_control_plane_labels || skipped_section 7  "Control Plane Labels"
  [[ "$RUN_API_ETCD_PODS"        == "true" ]] && check_api_etcd_pods        || skipped_section 8  "API Server & ETCD Pods"
  [[ "$RUN_ETCD_HEALTH"          == "true" ]] && check_etcd_health          || skipped_section 9  "ETCD Operator Conditions"
  [[ "$RUN_ETCD_MEMBER_HEALTH"   == "true" ]] && check_etcd_member_health   || skipped_section 10 "ETCD Member Health"
  [[ "$RUN_WEBHOOKS"             == "true" ]] && check_webhooks             || skipped_section 11 "Admission Webhooks"
  [[ "$RUN_DEPRECATED_APIS"      == "true" ]] && check_deprecated_apis      || skipped_section 12 "Deprecated APIs"
  [[ "$RUN_CERTIFICATES"         == "true" ]] && check_certificates         || skipped_section 13 "TLS Certificates"
  [[ "$RUN_PENDING_CSRS"         == "true" ]] && check_pending_csrs         || skipped_section 14 "Pending CSRs"
  [[ "$RUN_CRITICAL_ALERTS"      == "true" ]] && check_critical_alerts      || skipped_section 15 "Critical Prometheus Alerts"
  [[ "$RUN_WORKLOADS"            == "true" ]] && check_workloads            || skipped_section 16 "Workload Health"
  [[ "$RUN_PDB"                  == "true" ]] && check_pdb                  || skipped_section 17 "PDB Analysis"
  [[ "$RUN_PVC"                  == "true" ]] && check_pvc                  || skipped_section 18 "PVC & PV Health"
  [[ "$RUN_DISK_SYSROOT"         == "true" ]] && check_disk_sysroot         || skipped_section 19 "Node Disk Usage"
  [[ "$RUN_EVENTS"               == "true" ]] && check_events               || skipped_section 20 "Recent Events"
  [[ "$RUN_ROUTES"               == "false" ]] && check_routes               || skipped_section 21 "Route Health"
  [[ "$RUN_EGRESSIP"             == "true" ]] && check_egressip             || skipped_section 22 "EgressIP Health"
  [[ "$RUN_HW_COMPAT"            == "true" ]] && check_hw_compat            || skipped_section 23 "Hardware Compatibility"
  [[ "$RUN_CLOUD_CREDS"          == "true" ]] && check_cloud_creds          || skipped_section 24 "Cloud Credential Operator"
  [[ "$RUN_CSI_COMPAT"           == "true" ]] && check_csi_compat           || skipped_section 25 "Third-party CSI Drivers"

  print_summary
}

main
exit "$EXIT_CODE"
