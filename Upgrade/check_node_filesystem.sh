#!/bin/bash

# Script: check_sysroot_disk.sh
# Purpose: Get /sysroot disk usage from all nodes in the OpenShift cluster, grouped by node roles,
# with master nodes displayed first, followed by infra and worker nodes, using node role labels,
# and include a timestamp for auditing.

# ANSI color codes
COLOR_CYAN="\e[36m"
COLOR_YELLOW="\e[33m"
COLOR_RED="\e[31m"
COLOR_WHITE="\e[0m"
COLOR_RESET="\e[0m"

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

# Ensure oc is available
if ! command -v oc &> /dev/null; then
    echo "$(colorize "$COLOR_RED" "Error: 'oc' command not found. Please ensure OpenShift CLI is installed and configured.")"
    exit 1
fi

# Check if user is logged into OpenShift
if ! oc whoami &> /dev/null; then
    echo "$(colorize "$COLOR_RED" "Error: Not logged into OpenShift. Please run 'oc login' first.")"
    exit 1
fi

# Print timestamp
timestamp=$(date)
echo "$(colorize "$COLOR_CYAN" "Timestamp: $timestamp")"
echo "$(colorize "$COLOR_CYAN" "Collecting /sysroot disk usage from all nodes, grouped by node roles...")"
echo "$(colorize "$COLOR_CYAN" "================================================================")"
echo ""

# Function to print table header
print_table_header() {
    printf "${COLOR_CYAN}%-40s %-20s %-10s %-10s %-10s %-10s %-15s${COLOR_RESET}\n" "NODE" "FILESYSTEM" "SIZE" "USED" "AVAIL" "USE%" "MOUNTED ON"
    printf "${COLOR_CYAN}%s${COLOR_RESET}\n" "---------------------------------------------------------------------------------------------"
}

# Function to process nodes for a given role
process_nodes() {
    local role="$1"
    local label="$2"
    echo "$(colorize "$COLOR_CYAN" "Node Role: $role")"
    echo "$(colorize "$COLOR_WHITE" "  Query: oc get nodes -l $label")"
    print_table_header
    nodes=$(oc get nodes -l "$label" -o name 2>/dev/null | awk -F'/' '{print $2}')
    if [[ $? -ne 0 ]]; then
        echo "$(colorize "$COLOR_RED" "  Error: Failed to query nodes for $role role. Check permissions with 'oc get nodes -l $label'.")"
    elif [[ -z "$nodes" ]]; then
        echo "$(colorize "$COLOR_RED" "  No nodes found with $role role. Verify node labels with 'oc get nodes -l $label'.")"
    else
        for node in $nodes; do
            # Check if node is accessible
            if ! oc get node "$node" &> /dev/null; then
                printf "${COLOR_YELLOW}%-40s${COLOR_RESET} ${COLOR_RED}%-20s %-10s %-10s %-10s %-10s %-15s${COLOR_RESET}\n" "$node" "Node inaccessible" "-" "-" "-" "-" "-"
                continue
            fi
            output=$(oc debug node/"$node" -- chroot /host df -h /sysroot 2>/dev/null | tail -n 1)
            if [[ $? -ne 0 || -z "$output" ]]; then
                printf "${COLOR_YELLOW}%-40s${COLOR_RESET} ${COLOR_RED}%-20s %-10s %-10s %-10s %-10s %-15s${COLOR_RESET}\n" "$node" "Error" "-" "-" "-" "-" "-"
                continue
            fi
            read -r filesystem size used avail use_percent mounted_on <<< "$output"
            if [[ -z "$filesystem" || -z "$size" ]]; then
                printf "${COLOR_YELLOW}%-40s${COLOR_RESET} ${COLOR_RED}%-20s %-10s %-10s %-10s %-10s %-15s${COLOR_RESET}\n" "$node" "No data" "-" "-" "-" "-" "-"
                continue
            fi
            found=true
            printf "${COLOR_YELLOW}%-40s${COLOR_RESET} ${COLOR_WHITE}%-20s %-10s %-10s %-10s %-10s %-15s${COLOR_RESET}\n" \
                "$node" "$filesystem" "$size" "$used" "$avail" "$use_percent" "$mounted_on"
        done
    fi
    echo ""
}

# Flag to track if any data is collected
found=false

# List all nodes for debugging
echo "$(colorize "$COLOR_CYAN" "Nodes in cluster:")"
nodes=$(oc get nodes -o name 2>/dev/null | awk -F'/' '{print $2}')
if [[ -z "$nodes" ]]; then
    echo "$(colorize "$COLOR_RED" "Error: No nodes found in cluster. Check permissions with 'oc get nodes'.")"
    echo "$(colorize "$COLOR_RED" "Troubleshooting steps:")"
    echo "$(colorize "$COLOR_RED" "  - Verify nodes: 'oc get nodes'")"
    echo "$(colorize "$COLOR_RED" "  - Check permissions: 'oc auth can-i get nodes'")"
    exit 1
else
    for node in $nodes; do
        echo "$(colorize "$COLOR_WHITE" "  - $node")"
    done
    echo ""
fi

# Process master nodes (using node-role.kubernetes.io/master=)
process_nodes "master" "node-role.kubernetes.io/master="

# Process infra nodes (using node-role.kubernetes.io/infra=)
process_nodes "infra" "node-role.kubernetes.io/infra="

# Process worker nodes (using node-role.kubernetes.io/worker=)
process_nodes "worker" "node-role.kubernetes.io/worker="

# Check if any data was collected
if [[ "$found" == "false" ]]; then
    echo "$(colorize "$COLOR_RED" "No /sysroot disk usage data collected from any nodes.")"
    echo "$(colorize "$COLOR_RED" "Troubleshooting steps:")"
    echo "$(colorize "$COLOR_RED" "  - Verify node roles: 'oc get nodes --show-labels'")"
    echo "$(colorize "$COLOR_RED" "  - Check master nodes: 'oc get nodes -l node-role.kubernetes.io/master='")"
    echo "$(colorize "$COLOR_RED" "  - Check infra nodes: 'oc get nodes -l node-role.kubernetes.io/infra='")"
    echo "$(colorize "$COLOR_RED" "  - Check worker nodes: 'oc get nodes -l node-role.kubernetes.io/worker='")"
    echo "$(colorize "$COLOR_RED" "  - Ensure permissions: 'oc auth can-i get nodes'")"
fi

echo "$(colorize "$COLOR_CYAN" "Done.")"
