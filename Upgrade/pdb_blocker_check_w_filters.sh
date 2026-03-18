#!/bin/bash

# =============================================================================
# PDB Blocker Checker - Advanced Edition
# Accurate disruption calculation using minAvailable / maxUnavailable logic.
#
# Usage:
#   ./pdb_blocker_check.sh [OPTIONS]
#
# Options:
#   --node=<nodename>     Show all PDBs in namespaces that have ANY pod on this node
#   --pdb=<name>          Filter by PDB name (substring match)
#   --namespace=<ns>      Filter by exact namespace name
#   --include-system      Include openshift-* system namespaces (excluded by default)
#   --blocked-only        Show only ACTIVE blockers (disruptionsAllowed=0 AND Running pods present)
#   --help                Show this help message
# =============================================================================

# ---- Color codes (use \e[ for echo -e compatibility) ----
RED='\e[31m'
ORANGE='\e[38;5;208m'
GREEN='\e[32m'
BLUE='\e[34m'
CYAN='\e[36m'
YELLOW='\e[33m'
BOLD='\e[1m'
NC='\e[0m'

# ---- Defaults ----
FILTER_NODE=""
FILTER_PDB=""
FILTER_NS=""
INCLUDE_SYSTEM=false
BLOCKED_ONLY=false

# ---- Parse arguments ----
for arg in "$@"; do
  case "$arg" in
    --node=*)         FILTER_NODE="${arg#--node=}" ;;
    --pdb=*)          FILTER_PDB="${arg#--pdb=}" ;;
    --namespace=*)    FILTER_NS="${arg#--namespace=}" ;;
    --include-system) INCLUDE_SYSTEM=true ;;
    --blocked-only)   BLOCKED_ONLY=true ;;
    --help)
      echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
      echo ""
      echo -e "${BOLD}Options:${NC}"
      echo "  --node=<nodename>     Show all PDBs in namespaces that have ANY pod on this node"
      echo "  --pdb=<n>          Filter by PDB name (substring match)"
      echo "  --namespace=<ns>      Filter by exact namespace name"
      echo "  --include-system      Include openshift-* system namespaces (excluded by default)"
      echo "  --blocked-only        Show only ACTIVE blockers: disruptionsAllowed=0"
      echo "                        AND at least one Running pod (inactive blockers"
      echo "                        with no Running pods are excluded as non-actionable)"
      echo "  --help                Show this help message"
      echo ""
      echo -e "${BOLD}Combined Mode — Node Drain Blocker Check:${NC}"
      echo "  --node=<nodename> --blocked-only"
      echo ""
      echo "    The fastest way to check if a node is safe to drain."
      echo "    Combines both filters to show ONLY the PDBs that are:"
      echo "      * disruptionsAllowed = 0  (will actively block the drain)"
      echo "      * in a namespace with at least one pod on the target node"
      echo ""
      echo "    Filter chain (runs in order):"
      echo "      1. Compute disruption status for all PDBs"
      echo "         (accurate minAvailable / maxUnavailable formula)"
      echo "      2. Keep only BLOCKED PDBs  (disruptionsAllowed = 0)"
      echo "      3. Single oc call to resolve all namespaces on the target node"
      echo "      4. Keep only BLOCKED PDBs whose namespace is in that set"
      echo ""
      echo "    Drain verdict printed at the end of the run:"
      echo "      CLEAR TO DRAIN  -- no blocking PDBs found for this node"
      echo "      DRAIN BLOCKED   -- N PDB(s) must be resolved before draining"
      echo ""
      echo -e "${BOLD}Examples:${NC}"
      echo "  # Full report -- all non-system PDBs with pod/node detail"
      echo "  $0"
      echo ""
      echo "  # All PDBs in namespaces with pods on a specific node"
      echo "  $0 --node=ip-10-0-1-45.ec2.internal"
      echo ""
      echo "  # Quick drain go/no-go for a node  (recommended pre-drain check)"
      echo "  $0 --node=ip-10-0-1-45.ec2.internal --blocked-only"
      echo ""
      echo "  # All ACTIVE blockers cluster-wide (Running pods + disruptionsAllowed=0)"
      echo "  $0 --blocked-only"
      echo ""
      echo "  # Drill into a specific PDB by name (substring match)"
      echo "  $0 --pdb=kafka"
      echo ""
      echo "  # Scope to a single namespace"
      echo "  $0 --namespace=my-app"
      echo ""
      echo "  # Namespace + blocked-only"
      echo "  $0 --namespace=my-app --blocked-only"
      echo ""
      echo "  # Include openshift-* system namespaces"
      echo "  $0 --include-system"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown argument: $arg${NC}" >&2
      echo "Run with --help for usage." >&2
      exit 1
      ;;
  esac
done

# ---- Preflight checks ----
for cmd in oc jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}Error: '$cmd' not found. Please install it and ensure it is in PATH.${NC}" >&2
    exit 1
  fi
done

if ! oc whoami &>/dev/null; then
  echo -e "${RED}Error: Not logged into OpenShift. Run 'oc login' first.${NC}" >&2
  exit 1
fi

# ---- Banner ----
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║          PDB Blocker Checker — Advanced              ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

FILTERS_ACTIVE=false
[[ -n "$FILTER_NODE" ]] && echo -e "  ${YELLOW}▶ Node filter      :${NC} $FILTER_NODE"  && FILTERS_ACTIVE=true
[[ -n "$FILTER_PDB"  ]] && echo -e "  ${YELLOW}▶ PDB name filter  :${NC} $FILTER_PDB"   && FILTERS_ACTIVE=true
[[ -n "$FILTER_NS"   ]] && echo -e "  ${YELLOW}▶ Namespace filter :${NC} $FILTER_NS"    && FILTERS_ACTIVE=true
$BLOCKED_ONLY           && echo -e "  ${YELLOW}▶ Blocked-only mode: ON (active blockers with Running pods only)${NC}" && FILTERS_ACTIVE=true
$INCLUDE_SYSTEM         && echo -e "  ${YELLOW}▶ System namespaces: INCLUDED${NC}"
$FILTERS_ACTIVE || echo -e "  ${CYAN}No filters — showing all non-system PDBs${NC}"

# ---- Combined mode: --node + --blocked-only = drain-blocker check -----------
if [[ -n "$FILTER_NODE" ]] && $BLOCKED_ONLY; then
  echo ""
  echo -e "  ${RED}${BOLD}  ╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${RED}${BOLD}  ║   NODE DRAIN BLOCKER CHECK MODE                     ║${NC}"
  echo -e "  ${RED}${BOLD}  ║   Showing ONLY PDBs that will BLOCK drain of:       ║${NC}"
  printf  "  ${RED}${BOLD}  ║   %-51s║${NC}\n" "Node: ${FILTER_NODE}"
  echo -e "  ${RED}${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"
fi
echo ""

# ---- Temp files ----
TMP_PDB=$(mktemp /tmp/pdb_check_XXXX.json)
TMP_COMPUTED=$(mktemp /tmp/pdb_computed_XXXX.tsv)
TMP_NS_FILTER=$(mktemp /tmp/pdb_ns_XXXX.txt)
trap 'rm -f "$TMP_PDB" "$TMP_COMPUTED" "$TMP_NS_FILTER"' EXIT

# =============================================================================
# STEP 1 — Fetch all PDBs
# =============================================================================
echo -e "${CYAN}Fetching PDB data...${NC}"
if ! oc get pdb -A -o json > "$TMP_PDB" 2>/dev/null; then
  echo -e "${RED}Error: Could not fetch PDBs. Check connectivity and permissions.${NC}" >&2
  exit 1
fi

PDB_COUNT=$(jq '.items | length' "$TMP_PDB")
echo -e "${CYAN}Found ${BOLD}${PDB_COUNT}${NC}${CYAN} PDBs cluster-wide.${NC}"
echo ""

# =============================================================================
# STEP 2 — Compute disruption status using accurate minAvailable/maxUnavailable
#           logic. Outputs TSV to TMP_COMPUTED.
# Fields: color | pct | ns | name | type | minval | maxval | expected | healthy | disruptions | selector | formula
# =============================================================================
jq -r --argjson inc "$( $INCLUDE_SYSTEM && echo true || echo false )" '
.items[] |
select(
  if $inc then true
  else (.metadata.namespace | test("^openshift") | not)
  end
) |
{
  ns:    .metadata.namespace,
  name:  .metadata.name,
  exp:   (.status.expectedPods   // 0),
  hlth:  (.status.currentHealthy // 0),
  minA:  .spec.minAvailable,
  maxU:  .spec.maxUnavailable,
  sel:   (.spec.selector.matchLabels // {}
          | to_entries | map("\(.key)=\(.value)") | join(","))
} as $p |
( $p.minA | if . != null then (if type=="number" then . else tonumber end) else null end ) as $minA |
( $p.maxU | if . != null then (if type=="number" then . else tonumber end) else null end ) as $maxU |
(
  if   $minA != null then
    { type:"minAvailable",
      calc: ($p.hlth - $minA),
      formula: "disruptionsAllowed = currentHealthy(\($p.hlth)) - minAvailable(\($minA)) = \($p.hlth - $minA)" }
  elif $maxU != null then
    { type:"maxUnavailable",
      calc: ($maxU - ($p.exp - $p.hlth)),
      formula: "disruptionsAllowed = maxUnavailable(\($maxU)) - (expectedPods(\($p.exp)) - currentHealthy(\($p.hlth))) = \($maxU - ($p.exp - $p.hlth))" }
  else
    { type:"none", calc:0, formula:"N/A (no minAvailable or maxUnavailable set)" }
  end
) as $r |
($r.calc | if . < 0 then 0 else . end) as $da |
($p.exp  | if . == 0 then 0 else (($da / .) * 100 + 0.5 | floor) end) as $pct |
(if $da == 0 then "RED" elif $pct==100 then "BLUE" elif $pct<30 then "ORANGE" else "GREEN" end) as $col |
[ $col, ($pct|tostring), $p.ns, $p.name, $r.type,
  (if $minA!=null then ($minA|tostring) else "N/A" end),
  (if $maxU!=null then ($maxU|tostring) else "N/A" end),
  ($p.exp|tostring), ($p.hlth|tostring), ($da|tostring),
  $p.sel, $r.formula
] | join("\t")
' "$TMP_PDB" > "$TMP_COMPUTED"

# =============================================================================
# STEP 3 — Apply --namespace and --pdb filters (awk on TSV)
# =============================================================================
if [[ -n "$FILTER_NS" ]]; then
  awk -F'\t' -v ns="$FILTER_NS" '$3 == ns' "$TMP_COMPUTED" > "${TMP_COMPUTED}.tmp" \
    && mv "${TMP_COMPUTED}.tmp" "$TMP_COMPUTED"
fi

if [[ -n "$FILTER_PDB" ]]; then
  awk -F'\t' -v pdb="$FILTER_PDB" '$4 ~ pdb' "$TMP_COMPUTED" > "${TMP_COMPUTED}.tmp" \
    && mv "${TMP_COMPUTED}.tmp" "$TMP_COMPUTED"
fi

if $BLOCKED_ONLY; then
  # Pre-filter to RED rows only — reduces pod lookups in STEP 5.
  # The active-only gate (skip inactive blockers) is applied inside the
  # display loop AFTER pod status is resolved, since pod phase is not
  # known at this stage.
  awk -F'\t' '$1 == "RED"' "$TMP_COMPUTED" > "${TMP_COMPUTED}.tmp" \
    && mv "${TMP_COMPUTED}.tmp" "$TMP_COMPUTED"
fi

# =============================================================================
# STEP 4 — --node filter: find all namespaces that have ANY pod on target node,
#           then keep only PDBs in those namespaces.
#           Uses a plain file for the namespace set (no associative array issues).
# =============================================================================
declare -A NODE_PODS_IN_NS   # ns -> TSV lines "podname\tnodename" on the target node

if [[ -n "$FILTER_NODE" ]]; then
  echo -e "${CYAN}Scanning pods on node ${BOLD}${FILTER_NODE}${NC}${CYAN}...${NC}"

  TMP_NODEPODS=$(mktemp /tmp/pdb_nodepods_XXXX.tsv)
  trap 'rm -f "$TMP_PDB" "$TMP_COMPUTED" "$TMP_NS_FILTER" "$TMP_NODEPODS"' EXIT

  # Single oc call — field-selector narrows to pods on the target node
  oc get pods -A \
    --field-selector="spec.nodeName=${FILTER_NODE}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' \
    2>/dev/null > "$TMP_NODEPODS"

  if [[ ! -s "$TMP_NODEPODS" ]]; then
    echo -e "${YELLOW}  Warning: No pods found on node '${FILTER_NODE}'. Check the node name.${NC}"
  fi

  # Build: TMP_NS_FILTER (unique namespaces) and NODE_PODS_IN_NS (per-ns pod list)
  while IFS=$'\t' read -r pns pname pnode; do
    [[ -z "$pns" ]] && continue
    echo "$pns" >> "$TMP_NS_FILTER"
    NODE_PODS_IN_NS["$pns"]+="${pname}"$'\t'"${pnode}"$'\n'
  done < "$TMP_NODEPODS"

  # Deduplicate namespace list
  sort -u "$TMP_NS_FILTER" -o "$TMP_NS_FILTER"
  NS_COUNT=$(wc -l < "$TMP_NS_FILTER")
  echo -e "${CYAN}  Found ${BOLD}${NS_COUNT}${NC}${CYAN} namespace(s) with pods on node ${BOLD}${FILTER_NODE}${NC}${CYAN}.${NC}"
  echo ""

  # Keep only PDB rows whose namespace is in TMP_NS_FILTER
  awk -F'\t' 'NR==FNR{ns[$1]=1; next} $3 in ns' \
    "$TMP_NS_FILTER" "$TMP_COMPUTED" > "${TMP_COMPUTED}.tmp" \
    && mv "${TMP_COMPUTED}.tmp" "$TMP_COMPUTED"

  # Combined mode note: if --blocked-only is also set, downstream awk already
  # filtered to RED rows; node filter then narrows to affected namespaces only.
  # Result = exact set of PDBs blocking drain of FILTER_NODE.
fi

# =============================================================================
# STEP 5 — Print layered PDB blocks + pod/node table
#
# Layout per PDB:
#   ── ROW 1 ──  NAMESPACE | PDB_NAME | TYPE | minAvailable | maxUnavailable | EXPECTED | HEALTHY | DISRUPTIONS | PCT
#   ── ROW 2 ──  Pods count line
#   ── ROW 3 ──  Selector label
#   ── TABLE ──  POD NAME | NODE | STATUS  (one row per pod)
#   ── CALC  ──  Formula explanation at the bottom
# =============================================================================

COUNT_BLOCKED=0          # RED: disruptionsAllowed=0 (any pod state)
COUNT_BLOCKED_ACTIVE=0   # RED: disruptionsAllowed=0 AND has Running pods  → real blocker
COUNT_BLOCKED_INACTIVE=0 # RED: disruptionsAllowed=0 AND no Running pods   → paper blocker
COUNT_LOW_HA=0; COUNT_SAFE=0; COUNT_FULL_OUTAGE=0; COUNT_PRINTED=0
SEP="${CYAN}$(printf '─%.0s' {1..110})${NC}"
THINSEP="${CYAN}$(printf '┄%.0s' {1..110})${NC}"

while IFS=$'\t' read -r color pct ns name type minval maxval expected healthy disruptions selector formula; do
  [[ -z "$color" ]] && continue

  # ---- counters (BLOCKED split happens after pod status check below) ----
  case "$color" in
    RED)    COUNT_BLOCKED=$((COUNT_BLOCKED+1)) ;;
    ORANGE) COUNT_LOW_HA=$((COUNT_LOW_HA+1)) ;;
    GREEN)  COUNT_SAFE=$((COUNT_SAFE+1)) ;;
    BLUE)   COUNT_FULL_OUTAGE=$((COUNT_FULL_OUTAGE+1)) ;;
  esac
  COUNT_PRINTED=$((COUNT_PRINTED+1))

  # ---- pick colors/badge ----
  case "$color" in
    RED)    C="$RED";    BADGE="[BLOCKED]"    ;;
    ORANGE) C="$ORANGE"; BADGE="[LOW-HA]"     ;;
    GREEN)  C="$GREEN";  BADGE="[SAFE]"        ;;
    BLUE)   C="$BLUE";   BADGE="[FULL-OUTAGE]" ;;
    *)      C="$NC";     BADGE="[UNKNOWN]"     ;;
  esac

  echo -e "$SEP"

  # ── ROW 1: PDB identity + numbers ──────────────────────────────────────────
  echo -e "${C}${BOLD}  ${BADGE}${NC}${BOLD}  NAMESPACE: ${C}${ns}${NC}${BOLD}  │  PDB: ${C}${name}${NC}"
  printf "${BOLD}  %-20s %-20s %-16s %-10s %-10s %-14s %-6s${NC}\n" \
    "TYPE" "minAvailable" "maxUnavailable" "EXPECTED" "HEALTHY" "DISRUPTIONS" "PCT"
  printf "${C}  %-20s %-20s %-16s %-10s %-10s %-14s %-6s${NC}\n" \
    "$type" "$minval" "$maxval" "$expected" "$healthy" "$disruptions" "${pct}%"

  echo -e "$THINSEP"

  # ── ROW 2: Pod count + selector ────────────────────────────────────────────
  echo -e "  ${BOLD}Selector :${NC} ${CYAN}${selector:-<none defined>}${NC}"

  # ── ROW 3+: Fetch pods via selector ────────────────────────────────────────
  ALL_PODS=()
  RUNNING_COUNT=0
  NON_RUNNING_COUNT=0
  if [[ -n "$selector" ]]; then
    mapfile -t ALL_PODS < <(
      oc get pods -n "$ns" --selector="$selector" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.status.phase}{"\n"}{end}' \
        2>/dev/null
    )
  fi

  # Count Running vs non-Running pods for this PDB
  for pod_line in "${ALL_PODS[@]}"; do
    [[ -z "$pod_line" ]] && continue
    IFS=$'\t' read -r _pn _pnd _ps <<< "$pod_line"
    if [[ "$_ps" == "Running" ]]; then
      RUNNING_COUNT=$((RUNNING_COUNT+1))
    else
      NON_RUNNING_COUNT=$((NON_RUNNING_COUNT+1))
    fi
  done

  # Classify RED PDBs as ACTIVE (real blocker) or INACTIVE (paper blocker)
  POD_HEALTH_VERDICT=""
  if [[ "$color" == "RED" ]]; then
    if [[ $RUNNING_COUNT -gt 0 ]]; then
      COUNT_BLOCKED_ACTIVE=$((COUNT_BLOCKED_ACTIVE+1))
      POD_HEALTH_VERDICT="ACTIVE_BLOCKER"
    else
      COUNT_BLOCKED_INACTIVE=$((COUNT_BLOCKED_INACTIVE+1))
      POD_HEALTH_VERDICT="INACTIVE_BLOCKER"
      # --blocked-only means show active blockers only — skip inactive ones
      if $BLOCKED_ONLY; then
        continue
      fi
    fi
  fi

  POD_COUNT="${#ALL_PODS[@]}"
  echo -e "  ${BOLD}Pod count:${NC} ${C}${POD_COUNT} pod(s) matched by this PDB  (Running: ${GREEN}${RUNNING_COUNT}${NC}  |  Non-Running: ${YELLOW}${NON_RUNNING_COUNT}${NC})${NC}"
  echo ""

  if [[ $POD_COUNT -eq 0 ]]; then
    echo -e "  ${YELLOW}  No pods currently matched by selector.${NC}"
  else
    # Pod/Node table header
    printf "  ${BOLD}${CYAN}  %-50s  %-42s  %-10s${NC}" "POD NAME" "NODE" "STATUS"
    [[ -n "$FILTER_NODE" ]] && printf "${BOLD}${CYAN}  %-10s${NC}" "ON NODE?"
    echo ""
    printf "  ${CYAN}  %s${NC}\n" "$(printf '─%.0s' {1..108})"

    for pod_line in "${ALL_PODS[@]}"; do
      [[ -z "$pod_line" ]] && continue
      IFS=$'\t' read -r pname pnode pstatus <<< "$pod_line"
      [[ -z "$pname"  ]] && continue
      [[ -z "$pnode"  ]] && pnode="<not scheduled>"
      [[ -z "$pstatus" ]] && pstatus="Unknown"

      case "$pstatus" in
        Running)  SC="$GREEN"  ;;
        Pending)  SC="$YELLOW" ;;
        Failed)   SC="$RED"    ;;
        *)        SC="$NC"     ;;
      esac

      printf "    %-50s  %-42s  ${SC}%-10s${NC}" "$pname" "$pnode" "$pstatus"

      if [[ -n "$FILTER_NODE" ]]; then
        if [[ "$pnode" == "$FILTER_NODE" ]]; then
          printf "  ${YELLOW}${BOLD}%-10s${NC}" "★ ON NODE"
        else
          printf "  ${NC}%-10s${NC}" "-"
        fi
      fi
      echo ""
    done
  fi

  # ── FORMULA + POD HEALTH VERDICT at the bottom of each PDB block ──────────
  echo ""
  echo -e "  ${BOLD}Calculation :${NC}"
  echo -e "    ${CYAN}${formula}${NC}"
  if [[ "$disruptions" -eq 0 ]]; then
    if [[ "$POD_HEALTH_VERDICT" == "ACTIVE_BLOCKER" ]]; then
      echo -e "    ${RED}${BOLD}→ disruptionsAllowed = 0  |  ${RUNNING_COUNT} Running pod(s) — REAL BLOCKER: will block maintenance / node drain${NC}"
    elif [[ "$POD_HEALTH_VERDICT" == "INACTIVE_BLOCKER" ]]; then
      echo -e "    ${YELLOW}${BOLD}→ disruptionsAllowed = 0  |  0 Running pods — PAPER BLOCKER: PDB is configured as blocked but no Running pods back it${NC}"
      echo -e "    ${YELLOW}  Eviction will succeed despite PDB config — safe to proceed with maintenance${NC}"
    else
      echo -e "    ${RED}${BOLD}→ disruptionsAllowed = 0 — this PDB will BLOCK maintenance / node drain${NC}"
    fi
  else
    echo -e "    ${C}→ disruptionsAllowed = ${disruptions} (${pct}% of expected pods)${NC}"
  fi
  echo ""

done < "$TMP_COMPUTED"

echo -e "$SEP"

# =============================================================================
# STEP 6 — Summary
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║                  SUMMARY REPORT                     ║${NC}"
echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════════════════╝${NC}"

[[ -n "$FILTER_NODE" || -n "$FILTER_PDB" || -n "$FILTER_NS" || "$BLOCKED_ONLY" == true ]] \
  && echo -e "  ${YELLOW}(Filtered view — counts reflect active filters)${NC}"
echo ""

printf "  ${RED}${BOLD}  %-38s${NC}  %s\n"    "Blocked (disruptionsAllowed=0):"          "$COUNT_BLOCKED"
printf "  ${RED}  %-38s${NC}  %s\n"           "  ↳ Active blockers (Running pods):"       "$COUNT_BLOCKED_ACTIVE"
printf "  ${YELLOW}  %-38s${NC}  %s\n"        "  ↳ Inactive blockers (no Running pods):"  "$COUNT_BLOCKED_INACTIVE"
printf "  ${ORANGE}${BOLD}  %-38s${NC}  %s\n" "Low HA / Caution (<30%% disrupts):"        "$COUNT_LOW_HA"
printf "  ${GREEN}${BOLD}  %-38s${NC}  %s\n"  "Safe (>=30%% disruptions allowed):"        "$COUNT_SAFE"
printf "  ${BLUE}${BOLD}  %-38s${NC}  %s\n"   "Full outage (100%% disruptions):"          "$COUNT_FULL_OUTAGE"
echo ""
printf "  ${BOLD}  %-38s  %s${NC}\n" "Total PDBs displayed:" "$COUNT_PRINTED"

if [[ -n "$FILTER_NODE" ]] && $BLOCKED_ONLY; then
  # Combined mode — drain verdict based on ACTIVE blockers only
  echo ""
  echo -e "  ${BOLD}${CYAN}  ── Drain Verdict for node: ${FILTER_NODE} ──${NC}"
  if [[ "$COUNT_BLOCKED_ACTIVE" -eq 0 && "$COUNT_BLOCKED" -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}  ✔  CLEAR TO DRAIN${NC}"
    echo -e "  ${GREEN}  No blocking PDBs found in namespaces with pods on this node.${NC}"
  elif [[ "$COUNT_BLOCKED_ACTIVE" -eq 0 && "$COUNT_BLOCKED_INACTIVE" -gt 0 ]]; then
    echo -e "  ${GREEN}${BOLD}  ✔  CLEAR TO DRAIN${NC}"
    echo -e "  ${GREEN}  $COUNT_BLOCKED_INACTIVE PDB(s) show disruptionsAllowed=0 but have NO Running pods.${NC}"
    echo -e "  ${GREEN}  These are paper blockers — eviction will succeed. Safe to drain.${NC}"
  else
    echo -e "  ${RED}${BOLD}  ✘  DRAIN BLOCKED — $COUNT_BLOCKED_ACTIVE active PDB blocker(s) with Running pods${NC}"
    if [[ "$COUNT_BLOCKED_INACTIVE" -gt 0 ]]; then
      echo -e "  ${YELLOW}  ($COUNT_BLOCKED_INACTIVE additional PDB(s) are inactive blockers — no Running pods, safe to ignore)${NC}"
    fi
    echo -e "  ${RED}  Resolve the ACTIVE BLOCKED PDB(s) listed above before draining.${NC}"
    echo -e "  ${RED}  Tip: scale up the workload or temporarily remove the PDB.${NC}"
  fi
elif [[ -n "$FILTER_NODE" ]]; then
  echo ""
  echo -e "  ${YELLOW}${BOLD}  Node scope :${NC} ${BOLD}${FILTER_NODE}${NC}"
  echo -e "  ${YELLOW}  All PDBs shown are in namespaces that have pods on this node.${NC}"
  echo -e "  ${YELLOW}  Re-run with --blocked-only for a focused drain-blocker check.${NC}"
fi

if [[ "$COUNT_BLOCKED" -gt 0 ]] && ! ( [[ -n "$FILTER_NODE" ]] && $BLOCKED_ONLY ); then
  echo ""
  if [[ "$COUNT_BLOCKED_ACTIVE" -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}  ⚠  ACTION REQUIRED:${NC} ${RED}$COUNT_BLOCKED_ACTIVE PDB(s) are ACTIVE BLOCKERS (disruptionsAllowed=0 with Running pods).${NC}"
    echo -e "  ${RED}  These will block node drain and cluster maintenance operations.${NC}"
  fi
  if [[ "$COUNT_BLOCKED_INACTIVE" -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}  ℹ  NOTE:${NC} ${YELLOW}$COUNT_BLOCKED_INACTIVE PDB(s) are INACTIVE BLOCKERS (disruptionsAllowed=0 but no Running pods).${NC}"
    echo -e "  ${YELLOW}  These will NOT block maintenance — eviction will succeed as no Running pods are present.${NC}"
  fi
fi

if [[ "$COUNT_FULL_OUTAGE" -gt 0 ]]; then
  echo ""
  echo -e "  ${ORANGE}${BOLD}  ⚠  WARNING:${NC} ${ORANGE}$COUNT_FULL_OUTAGE PDB(s) allow 100%% disruption.${NC}"
  echo -e "  ${ORANGE}  These workloads may experience full downtime during maintenance.${NC}"
fi

echo ""
echo -e "${CYAN}  Done.${NC}"
echo ""
