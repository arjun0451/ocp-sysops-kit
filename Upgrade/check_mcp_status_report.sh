###MCP Overall summary
#!/bin/bash

# Generate a summary report of Machine Config Pool (MCP) status, node-level Machine Config details,
# and maxUnavailable settings for an OpenShift cluster.
# Usage: ./mcp_status_report.sh

# ANSI color codes
COLOR_CYAN="\e[36m"
COLOR_YELLOW="\e[33m"
COLOR_RED="\e[31m"
COLOR_WHITE="\e[0m"
COLOR_RESET="\e[0m"

# Debug log file
DEBUG_LOG="/tmp/mcp_status_debug.log"

# Function to apply color if enabled
colorize() {
    local color="$1"
    local text="$2"
    if [[ "$USE_COLORS" == "true" ]]; then
        echo -e "${color}${text}${COLOR_RESET}"
    else
        echo -e "$text"
    fi
}

# Check if terminal supports colors
if [[ -t 1 && $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    USE_COLORS=true
else
    USE_COLORS=false
    COLOR_CYAN=""
    COLOR_YELLOW=""
    COLOR_RED=""
    COLOR_WHITE=""
    COLOR_RESET=""
fi

# Ensure oc is available
if ! command -v oc &> /dev/null; then
    echo "$(colorize "$COLOR_RED" "Error: 'oc' command not found. Please ensure OpenShift CLI is installed and configured.")"
    exit 1
fi

# Ensure jq is available
if ! command -v jq &> /dev/null; then
    echo "$(colorize "$COLOR_RED" "Error: 'jq' command not found. Please install jq.")"
    echo "$(colorize "$COLOR_RED" "On RHEL/CentOS, run: sudo yum install jq")"
    echo "$(colorize "$COLOR_RED" "On Ubuntu/Debian, run: sudo apt-get install jq")"
    exit 1
fi

# Check jq version for compatibility
jq_version=$(jq --version 2>/dev/null | grep -o '[0-9]\.[0-9]' || echo "unknown")
if [[ "$jq_version" < "1.5" ]]; then
    echo "$(colorize "$COLOR_YELLOW" "Warning: jq version $jq_version is old. Some features may not work. Consider upgrading to jq 1.5 or higher.")"
    echo "jq version: $jq_version" >> "$DEBUG_LOG"
fi

# Check if user is logged into OpenShift
if ! oc whoami &> /dev/null; then
    echo "$(colorize "$COLOR_RED" "Error: Not logged into OpenShift. Please run 'oc login'.")"
    exit 1
fi

# Initialize debug log
echo "Debug log for run at $(date)" > "$DEBUG_LOG"

# Print timestamp
timestamp=$(date)
echo "$(colorize "$COLOR_CYAN" "Timestamp: $timestamp")"
echo "$(colorize "$COLOR_CYAN" "Generating Machine Config Pool (MCP) Status Report...")"
echo "$(colorize "$COLOR_CYAN" "================================================================")"
echo ""

# Function to print node table header
print_node_table_header() {
    printf "${COLOR_CYAN}%-40s %-35s %-35s %-15s %-15s${COLOR_RESET}\n" \
        "Node" "Current MC" "Desired MC" "MC State" "MC Status"
    printf "${COLOR_CYAN}%s${COLOR_RESET}\n" \
        "---------------------------------------------------------------------------------------------"
}

# Get node and MCP data
node_json=$(oc get nodes -o json 2>/dev/null)
mcp_json=$(oc get mcp -o json 2>/dev/null)

if [[ $? -ne 0 || -z "$node_json" ]]; then
    echo "$(colorize "$COLOR_RED" "Error: Failed to retrieve node data. Check permissions with 'oc get nodes'.")"
    exit 1
fi

if [[ $? -ne 0 || -z "$mcp_json" ]]; then
    echo "$(colorize "$COLOR_RED" "Error: Failed to retrieve MCP data. Check permissions with 'oc get mcp'.")"
    exit 1
fi

# Log raw JSON
echo "Raw node JSON:" >> "$DEBUG_LOG"
echo "$node_json" >> "$DEBUG_LOG"
echo "Raw MCP JSON:" >> "$DEBUG_LOG"
echo "$mcp_json" >> "$DEBUG_LOG"

# Process MCPs
mcp_names=$(echo "$mcp_json" | jq -r '.items[].metadata.name' | sort)
if [[ -z "$mcp_names" ]]; then
    echo "$(colorize "$COLOR_RED" "Error: No MCPs found in cluster. Verify with 'oc get mcp'.")"
    exit 1
fi

# Initialize summary data
mismatch_count=0
non_done_count=0
paused_mcps=""
degraded_mcps=""
mcp_max_unavailable=()
found=false

# Process nodes by MCP
for mcp in $mcp_names; do
    echo "$(colorize "$COLOR_CYAN" "MCP: $mcp")"
    print_node_table_header
    # Get nodes for this MCP (strictly by mcp label or role label)
    nodes=$(echo "$node_json" | jq -r --arg mcp "$mcp" '
        .items[] |
        select(
            (.metadata.labels["machineconfiguration.openshift.io/mcp"] // "") == $mcp or
            (.metadata.labels["node-role.kubernetes.io/" + $mcp] == "" and
             (.metadata.labels | has("machineconfiguration.openshift.io/mcp") | not))
        ) |
        {
            name: .metadata.name,
            current: (.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] // "N/A"),
            desired: (.metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] // "N/A"),
            state: (.metadata.annotations["machineconfiguration.openshift.io/state"] // "N/A")
        } |
        "\(.name)|\(.current)|\(.desired)|\(.state)"
    ' 2>>"$DEBUG_LOG" | sort)
    
    if [[ -z "$nodes" ]]; then
        echo "$(colorize "$COLOR_RED" "  No nodes found for MCP $mcp. Verify node labels with 'oc get nodes --show-labels'.")"
        echo ""
        continue
    fi

    # Process each node
    while IFS='|' read -r node current desired state; do
        echo "Processing node $node for MCP $mcp: current=$current, desired=$desired, state=$state" >> "$DEBUG_LOG"
        mc_status="Match"
        node_color="$COLOR_YELLOW"
        if [[ "$current" != "$desired" ]]; then
            mc_status="Mismatch"
            node_color="$COLOR_RED"
            ((mismatch_count++))
        fi
        if [[ "$state" != "Done" && "$state" != "N/A" ]]; then
            node_color="$COLOR_RED"
            ((non_done_count++))
        fi
        found=true
        printf "${node_color}%-40s${COLOR_RESET} ${COLOR_WHITE}%-35s %-35s %-15s %-15s${COLOR_RESET}\n" \
            "$node" "$current" "$desired" "$state" "$mc_status"
    done <<< "$nodes"
    echo ""
done

# MCP Status Section
echo "$(colorize "$COLOR_CYAN" "MCP Status:")"
mcp_status=$(echo "$mcp_json" | jq -r '.items[] | 
    {
        name: .metadata.name,
        paused: (.spec.paused // false),
        maxUnavailable: (.spec.maxUnavailable // 1),
        degraded: (if .status.conditions then (.status.conditions[] | select(.type == "Degraded") | .status == "True") else false end)
    } | 
    "\(.name) - paused: \(.paused), maxUnavailable: \(.maxUnavailable), degraded: \(.degraded)"' 2>>"$DEBUG_LOG" | sort)
if [[ -z "$mcp_status" ]]; then
    echo "$(colorize "$COLOR_RED" "  No MCP status information available. Check debug log for errors.")"
    # Fallback: populate maxUnavailable with default 1 for each MCP
    for mcp in $mcp_names; do
        mcp_max_unavailable+=("$mcp:1")
        echo "Fallback: Setting maxUnavailable=1 for MCP $mcp" >> "$DEBUG_LOG"
    done
else
    while IFS= read -r line; do
        echo "$(colorize "$COLOR_WHITE" "  $line")"
        echo "MCP status: $line" >> "$DEBUG_LOG"
        # Store maxUnavailable for summary
        mcp_name=$(echo "$line" | awk '{print $1}')
        max_unavailable=$(echo "$line" | grep -o 'maxUnavailable: [^,]*' | cut -d' ' -f2)
        mcp_max_unavailable+=("$mcp_name:$max_unavailable")
        # Update paused and degraded data
        if [[ "$line" =~ paused:\ true ]]; then
            paused_mcps="$paused_mcps $mcp_name"
        fi
        if [[ "$line" =~ degraded:\ True ]]; then
            degraded_mcps="$degraded_mcps $mcp_name"
        fi
    done <<< "$mcp_status"
fi
echo ""

# Summary Section
echo "$(colorize "$COLOR_CYAN" "Summary:")"
if [[ $mismatch_count -gt 0 ]]; then
    echo "$(colorize "$COLOR_RED" "  Nodes with mismatched Machine Configs: $mismatch_count")"
else
    echo "$(colorize "$COLOR_WHITE" "  Nodes with mismatched Machine Configs: 0")"
fi
if [[ $non_done_count -gt 0 ]]; then
    echo "$(colorize "$COLOR_RED" "  Nodes with non-Done state: $non_done_count")"
else
    echo "$(colorize "$COLOR_WHITE" "  Nodes with non-Done state: 0")"
fi
if [[ -n "$paused_mcps" ]]; then
    echo "$(colorize "$COLOR_RED" "  Paused MCPs:${paused_mcps}")"
else
    echo "$(colorize "$COLOR_WHITE" "  Paused MCPs: None")"
fi
if [[ -n "$degraded_mcps" ]]; then
    echo "$(colorize "$COLOR_RED" "  Degraded MCPs:${degraded_mcps}")"
else
    echo "$(colorize "$COLOR_WHITE" "  Degraded MCPs: None")"
fi
# Print maxUnavailable for each MCP
if [[ ${#mcp_max_unavailable[@]} -eq 0 ]]; then
    echo "$(colorize "$COLOR_RED" "  No maxUnavailable data available. Check MCP status.")"
else
    for mcp_max in "${mcp_max_unavailable[@]}"; do
        mcp_name=$(echo "$mcp_max" | cut -d':' -f1)
        max_value=$(echo "$mcp_max" | cut -d':' -f2-)
        echo "$(colorize "$COLOR_WHITE" "  MCP $mcp_name maxUnavailable: $max_value")"
    done
fi
echo ""

# Check if any data was collected
if [[ "$found" == "false" ]]; then
    echo "$(colorize "$COLOR_RED" "No MCP or node data collected.")"
    echo "$(colorize "$COLOR_RED" "Troubleshooting steps:")"
    echo "$(colorize "$COLOR_RED" "  - Verify MCPs: 'oc get mcp'")"
    echo "$(colorize "$COLOR_RED" "  - Verify nodes: 'oc get nodes --show-labels'")"
    echo "$(colorize "$COLOR_RED" "  - Check permissions: 'oc auth can-i get nodes' and 'oc auth can-i get mcp'")"
fi

echo "$(colorize "$COLOR_CYAN" "Debug log saved to $DEBUG_LOG")"
echo "$(colorize "$COLOR_CYAN" "Done.")"
