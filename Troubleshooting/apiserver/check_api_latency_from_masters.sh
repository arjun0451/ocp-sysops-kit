#!/bin/bash
# ----------------------------------------------------------------------------
# Script: check_api_latency_from_masters.sh
# Purpose: Measure OpenShift API connectivity timings from each master node
# ----------------------------------------------------------------------------

# --- Configuration ------------------------------------------------------
OCP_URL="api.<example.come>:6443"

# Thresholds in milliseconds - tune these for your environment
declare -A WARN_MS=( [dns]=5   [connect]=10  [tls]=50   [transfer]=100 [total]=100 )
declare -A CRIT_MS=( [dns]=20  [connect]=50  [tls]=150  [transfer]=300 [total]=300 )

# --- Colors ---------------------------------------------------------------
C_RED=$'\033[0;31m'
C_YELLOW=$'\033[0;33m'
C_GREEN=$'\033[0;32m'
C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

# --- Helpers ----------------------------------------------------------------

# Classify a value against warn/crit thresholds -> OK / WARN / CRIT
status_for() {
    local value="$1" warn="$2" crit="$3"
    awk -v v="$value" -v w="$warn" -v c="$crit" \
        'BEGIN { if (v >= c) print "CRIT"; else if (v >= w) print "WARN"; else print "OK" }'
}

color_for_status() {
    case "$1" in
        OK)   printf '%s' "$C_GREEN" ;;
        WARN) printf '%s' "$C_YELLOW" ;;
        CRIT) printf '%s' "$C_RED" ;;
    esac
}

# Print one metric row: label | value (ms) | status
print_row() {
    local label="$1" value_ms="$2" status="$3" color
    color=$(color_for_status "$status")
    printf "  %-18s %s%10.3f ms%s   %s%-6s%s\n" \
        "$label" "$color" "$value_ms" "$C_RESET" "$color" "$status" "$C_RESET"
}

# --- Main ---------------------------------------------------------------

MASTER_NODES=$(oc get nodes -l node-role.kubernetes.io/master= -o name | cut -d'/' -f2)

if [[ -z "$MASTER_NODES" ]]; then
    echo "No master nodes found. Check your oc login/context." >&2
    exit 1
fi

echo ""
echo "${C_BOLD}OpenShift API Connectivity Check${C_RESET}"
echo "Endpoint: https://$OCP_URL"
echo "================================================================================"

declare -a SUMMARY_ROWS

for NODE in $MASTER_NODES; do
    echo ""
    echo "${C_BOLD}Node: $NODE${C_RESET}"
    echo "--------------------------------------------------------------------------"

    RAW=$(oc debug node/"$NODE" --quiet -- chroot /host curl -k -s -o /dev/null \
        -w '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}' \
        "https://$OCP_URL" 2>/dev/null)

    if [[ -z "$RAW" ]]; then
        echo "  ${C_RED}Failed to reach endpoint from this node.${C_RESET}"
        echo "--------------------------------------------------------------------------"
        continue
    fi

    read -r DNS CONNECT TLS TRANSFER TOTAL <<< "$RAW"

    DNS_MS=$(awk -v v="$DNS" 'BEGIN{printf "%.3f", v*1000}')
    CONNECT_MS=$(awk -v v="$CONNECT" 'BEGIN{printf "%.3f", v*1000}')
    TLS_MS=$(awk -v v="$TLS" 'BEGIN{printf "%.3f", v*1000}')
    TRANSFER_MS=$(awk -v v="$TRANSFER" 'BEGIN{printf "%.3f", v*1000}')
    TOTAL_MS=$(awk -v v="$TOTAL" 'BEGIN{printf "%.3f", v*1000}')

    printf "  %-18s %10s   %s\n" "Metric" "Time" "Status"
    print_row "DNS Lookup"     "$DNS_MS"      "$(status_for "$DNS_MS" "${WARN_MS[dns]}" "${CRIT_MS[dns]}")"
    print_row "Connect"        "$CONNECT_MS"  "$(status_for "$CONNECT_MS" "${WARN_MS[connect]}" "${CRIT_MS[connect]}")"
    print_row "TLS Handshake"  "$TLS_MS"      "$(status_for "$TLS_MS" "${WARN_MS[tls]}" "${CRIT_MS[tls]}")"
    print_row "Start Transfer" "$TRANSFER_MS" "$(status_for "$TRANSFER_MS" "${WARN_MS[transfer]}" "${CRIT_MS[transfer]}")"
    print_row "Total"          "$TOTAL_MS"    "$(status_for "$TOTAL_MS" "${WARN_MS[total]}" "${CRIT_MS[total]}")"

    echo "--------------------------------------------------------------------------"

    TOTAL_STATUS=$(status_for "$TOTAL_MS" "${WARN_MS[total]}" "${CRIT_MS[total]}")
    SUMMARY_ROWS+=("$NODE|$TOTAL_MS|$TOTAL_STATUS")
done

echo ""
echo "================================================================================"
echo "${C_BOLD}Summary (Total time per node)${C_RESET}"
echo "--------------------------------------------------------------------------"
printf "  %-30s %12s   %s\n" "Node" "Total" "Status"
for ROW in "${SUMMARY_ROWS[@]}"; do
    IFS='|' read -r NODE TOTAL_MS STATUS <<< "$ROW"
    COLOR=$(color_for_status "$STATUS")
    printf "  %-30s %s%9.3f ms%s   %s%-6s%s\n" "$NODE" "$COLOR" "$TOTAL_MS" "$C_RESET" "$COLOR" "$STATUS" "$C_RESET"
done
echo "================================================================================"
echo "Connectivity test complete."
