#!/bin/bash
# Script: check_ephemeral_storage_nodewise.sh
# Purpose: List top 10 ephemeral storage consumers (EmptyDir volumes) per node, mapping pod UID to pod names
# Includes completed pods like must-gather

# ANSI colors
COLOR_CYAN="\e[36m"
COLOR_YELLOW="\e[33m"
COLOR_RED="\e[31m"
COLOR_WHITE="\e[0m"
COLOR_RESET="\e[0m"

colorize() {
    local color="$1"
    local text="$2"
    echo -e "${color}${text}${COLOR_RESET}"
}

# Check oc CLI
if ! command -v oc &>/dev/null; then
    echo "$(colorize "$COLOR_RED" "Error: 'oc' CLI not found")"
    exit 1
fi

# Check login
if ! oc whoami &>/dev/null; then
    echo "$(colorize "$COLOR_RED" "Error: Not logged into OpenShift")"
    exit 1
fi

echo "$(colorize "$COLOR_CYAN" "Timestamp: $(date)")"
echo "$(colorize "$COLOR_CYAN" "Scanning ephemeral storage usage (EmptyDir volumes) per node...")"
echo ""

# Get all pod UID → pod_name/namespace mapping (including completed pods)
pod_mapping=$(oc get pods --all-namespaces -o custom-columns="NAMESPACE:.metadata.namespace,POD:.metadata.name,UID:.metadata.uid" --no-headers)

# Get all nodes
nodes=$(oc get nodes -o name | awk -F'/' '{print $2}')

for node in $nodes; do
    echo "$(colorize "$COLOR_CYAN" "Node: $node")"
    echo "$(colorize "$COLOR_CYAN" "Top 10 ephemeral storage consumers (EmptyDir volumes)")"
    printf "%-60s %-20s %-10s\n" "POD_NAME (namespace)" "POD_UID" "SIZE"

    # Scan EmptyDir volumes on the node
    oc debug node/$node -- chroot /host bash -c '
        for dir in /var/lib/kubelet/pods/*/volumes/kubernetes.io~empty-dir/*; do
            if [ -d "$dir" ]; then
                size=$(du -sh "$dir" 2>/dev/null | awk "{print \$1}")
                # Extract pod UID reliably
                poduid=$(echo "$dir" | awk -F"/" "{for(i=1;i<=NF;i++){if(\$i==\"pods\"){print \$(i+1); break}}}")
                echo -e "$size\t$poduid"
            fi
        done
    ' 2>/dev/null | sort -hr | head -n 10 | while read size poduid; do

        # Map pod UID to pod name/namespace
        pod_info=$(echo "$pod_mapping" | awk -v uid="$poduid" '$3==uid {print $1"/"$2}')
        [ -z "$pod_info" ] && pod_info="completed/unknown"

        printf "%-60s %-20s %-10s\n" "$pod_info" "$poduid" "$size"
    done

    echo ""
done

echo "$(colorize "$COLOR_CYAN" "Done scanning ephemeral storage usage.")"
