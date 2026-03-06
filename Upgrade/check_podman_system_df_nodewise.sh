#!/bin/bash
# Script: check_podman_system_df_nodewise.sh
# Purpose: Collect 'podman system df' output from all OpenShift nodes and print it node-by-node.
# Adds size threshold warnings for high Podman image storage usage.
# Author: Nagarjuna (for OpenShift infra diagnostics)
# podman system prune -a ( to clean up the unused images from the node and recliam the space)

# ANSI colors
COLOR_CYAN="\e[36m"
COLOR_YELLOW="\e[33m"
COLOR_RED="\e[31m"
COLOR_GREEN="\e[32m"
COLOR_RESET="\e[0m"

THRESHOLD_GB=50  # Warning threshold in GB for total image size

colorize() {
    local color="$1"
    local text="$2"
    echo -e "${color}${text}${COLOR_RESET}"
}

# Check for oc CLI
if ! command -v oc &>/dev/null; then
    colorize "$COLOR_RED" "Error: 'oc' CLI not found in PATH. Please install or load OpenShift client tools."
    exit 1
fi

# Check OpenShift login
if ! oc whoami &>/dev/null; then
    colorize "$COLOR_RED" "Error: Not logged into OpenShift. Run 'oc login' and try again."
    exit 1
fi

echo ""
colorize "$COLOR_CYAN" "==================================================================="
colorize "$COLOR_CYAN" "Timestamp: $(date)"
colorize "$COLOR_CYAN" "Collecting 'podman system df' output from all nodes..."
colorize "$COLOR_CYAN" "==================================================================="
echo ""

nodes=$(oc get nodes -o name | awk -F'/' '{print $2}')

if [[ -z "$nodes" ]]; then
    colorize "$COLOR_RED" "No nodes found. Check 'oc get nodes' output."
    exit 1
fi

for node in $nodes; do
    echo ""
    colorize "$COLOR_YELLOW" "-----------------------------------------------------------"
    colorize "$COLOR_CYAN" "Node: $node"
    colorize "$COLOR_YELLOW" "-----------------------------------------------------------"

    # Run podman system df and capture output
    output=$(oc debug node/$node --quiet -- chroot /host bash -c '
        if command -v podman &>/dev/null; then
            podman system df 2>/dev/null
        else
            echo "Podman not installed or not available on this node"
        fi
    ' 2>/dev/null)

    echo "$output"
    echo ""

    # Extract image storage size and warn if above threshold
    image_size=$(echo "$output" | awk '/Images/ {print $4}' | head -n 1)

    if [[ "$image_size" =~ [0-9]+(\.[0-9]+)?G ]]; then
        size_val=$(echo "$image_size" | sed 's/G//')
        if (( $(echo "$size_val > $THRESHOLD_GB" | bc -l) )); then
            colorize "$COLOR_RED" "⚠️  Warning: Podman image storage = ${image_size}, exceeds ${THRESHOLD_GB}GB on node $node"
        else
            colorize "$COLOR_GREEN" "✅  Podman image storage within limit (${image_size})"
        fi
    fi

done

echo ""
colorize "$COLOR_CYAN" "==================================================================="
colorize "$COLOR_CYAN" "Done collecting Podman disk usage information from all nodes."
colorize "$COLOR_CYAN" "==================================================================="
