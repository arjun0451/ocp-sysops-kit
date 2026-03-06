#!/bin/bash
# Script: top10_writablelayer_containers.sh
# Purpose: List top 10 containers by writable-layer disk usage per node

# ===============================
# Colors
# ===============================
C_CYAN="\e[36m"
C_RED="\e[31m"
C_RESET="\e[0m"

colorize() {
    echo -e "${1}${2}${C_RESET}"
}

# ===============================
# Prechecks
# ===============================
if ! command -v oc &>/dev/null; then
    colorize "$C_RED" "ERROR: oc command not found"
    exit 1
fi

if ! oc whoami &>/dev/null; then
    colorize "$C_RED" "ERROR: Not logged into OpenShift"
    exit 1
fi

echo ""
colorize "$C_CYAN" "Timestamp: $(date)"
colorize "$C_CYAN" "Collecting writable-layer disk usage from all nodes..."
echo ""

# ===============================
# pod mapping (namespace + pod)
# ===============================
pod_mapping=$(oc get pods --all-namespaces \
    -o custom-columns="NS:.metadata.namespace,POD:.metadata.name,UID:.metadata.uid" \
    --no-headers)

# ===============================
# Loop through all nodes
# ===============================
nodes=$(oc get nodes -o name | sed 's|node/||')

for node in $nodes; do
    echo ""
    colorize "$C_CYAN" "========== Node: $node =========="
    colorize "$C_CYAN" "Top 10 writable-layer disk usage containers"

    # ===========================================
    # Run crictl stats INSIDE the node via debug
    # ===========================================
    stats=$(
        oc debug node/$node --quiet -- chroot /host bash -c '
            crictl stats -o json
        ' 2>/dev/null
    )

    if [[ -z "$stats" ]]; then
        colorize "$C_RED" "Failed to collect stats from $node"
        continue
    fi

    # ===========================================
    # Extract:
    # - container ID
    # - container name
    # - pod UID
    # - disk used (bytes)
    # ===========================================
    parsed=$(
        echo "$stats" | jq -r '
            .stats[] |
            [
                .attributes.id,
                .attributes.metadata.name,
                .attributes.labels["io.kubernetes.pod.uid"],
                (.writableLayer.usedBytes.value // 0)
            ] | @tsv
        '
    )

    # skip if empty
    if [[ -z "$parsed" ]]; then
        colorize "$C_RED" "No running containers found on node $node"
        continue
    fi

    # ===========================================
    # Sort by disk usage & take top 10
    # ===========================================
    echo ""
    printf "%-15s %-40s %-50s %-10s\n" "SIZE(MB)" "CONTAINER" "POD (namespace)" "POD_UID"

    echo "$parsed" | sort -k4 -nr | head -n 10 | while IFS=$'\t' read -r cid cname poduid used; do

        # Convert bytes to MB
        size_mb=$(( used / 1024 / 1024 ))

        # Map UID → namespace/pod
        pod_info=$(echo "$pod_mapping" | awk -v uid="$poduid" '$3 == uid {print $1 "/" $2}')

        [[ -z "$pod_info" ]] && pod_info="unknown/terminated"

        printf "%-15s %-40s %-50s %-10s\n" "${size_mb}MB" "$cname" "$pod_info" "$poduid"

    done

    echo ""
done

colorize "$C_CYAN" "Completed: Writable-layer disk usage scanning."
