## CPU and Memory Check for the node by pool

#!/bin/bash

# Collect memory and CPU usage from OpenShift cluster nodes, grouped by roles (master, infra, worker).
# Highlight nodes with CPU or memory usage exceeding an integer threshold (default 70%).
# Usage: ./check_cpu_memory_usage.sh [<threshold>]
# Example: ./check_cpu_memory_usage.sh 50 for 50%

# ANSI color codes
COLOR_CYAN="\e[36m"
COLOR_YELLOW="\e[33m"
COLOR_RED="\e[31m"
COLOR_WHITE="\e[0m"
COLOR_RESET="\e[0m"

# Debug log file
DEBUG_LOG="/tmp/check_cpu_memory_usage.debug.log"

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

# Default threshold
DEFAULT_THRESHOLD=70

# Parse command-line argument (integer only)
THRESHOLD="$1"
if [[ "$THRESHOLD" =~ ^[0-9]+$ && "$THRESHOLD" -ge 0 && "$THRESHOLD" -le 100 ]]; then
    :
else
    THRESHOLD="$DEFAULT_THRESHOLD"
    [[ -n "$1" ]] && echo "$(colorize "$COLOR_RED" "Error: Threshold must be an integer between 0 and 100. Using default: $DEFAULT_THRESHOLD%.")"
fi

# Check if bc is available
BC_AVAILABLE=false
if command -v bc &> /dev/null; then
    BC_AVAILABLE=true
else
    echo "$(colorize "$COLOR_YELLOW" "Warning: 'bc' command not found. Using awk for calculations, which may be less precise.")"
    echo "$(colorize "$COLOR_YELLOW" "To install bc on RHEL/CentOS, run: sudo yum install bc")"
    echo "$(colorize "$COLOR_YELLOW" "On Ubuntu/Debian, run: sudo apt-get install bc")"
fi

# Ensure oc is available
if ! command -v oc &> /dev/null; then
    echo "$(colorize "$COLOR_RED" "Error: 'oc' command not found. Please ensure OpenShift CLI is installed and configured.")"
    exit 1
fi

# Check if user is logged into OpenShift
if ! oc whoami &> /dev/null; then
    echo "$(colorize "$COLOR_RED" "Error: Not logged into OpenShift. Please run 'oc login'.")"
    exit 1
fi

# Print timestamp and threshold
timestamp=$(date)
echo "$(colorize "$COLOR_CYAN" "Timestamp: $timestamp")"
echo "$(colorize "$COLOR_CYAN" "Using threshold: $THRESHOLD% for high CPU and memory usage")"
echo "$(colorize "$COLOR_CYAN" "Collecting memory and CPU usage from all nodes, grouped by node roles...")"
echo "$(colorize "$COLOR_CYAN" "================================================================")"
echo ""

# Function to print table header
print_table_header() {
    printf "${COLOR_CYAN}%-40s %-10s %-10s %-10s %-10s %-10s %-10s %-10s %-30s${COLOR_RESET}\n" \
        "NODE" "MEM TOTAL" "MEM USED" "MEM FREE" "MEM AVAIL" "CPU %USER" "CPU %SYS" "CPU %IDLE" "NOTES"
    printf "${COLOR_CYAN}%s${COLOR_RESET}\n" \
        "---------------------------------------------------------------------------------------------"
}

# Function to convert memory value to MiB
convert_to_mib() {
    local value="$1"
    local unit="${value//[0-9.]/}"
    local num="${value%$unit}"
    if [[ "$unit" == "Gi" ]]; then
        echo "$(calculate "$num * 1024")"
    elif [[ "$unit" == "Mi" ]]; then
        echo "$num"
    elif [[ "$unit" == "Ki" ]]; then
        echo "$(calculate "$num / 1024")"
    else
        echo "0.0"
    fi
}

# Function to calculate floating-point operations
calculate() {
    local expr="$1"
    local result
    if [[ "$BC_AVAILABLE" == "true" ]]; then
        result=$(echo "scale=1; $expr" | bc)
    else
        result=$(awk "BEGIN {printf \"%.1f\", $expr}")
    fi
    echo "Calculate: $expr = $result" >> "$DEBUG_LOG"
    echo "$result"
}

# Function to compare floating-point numbers
compare_gt() {
    local value="$1"
    local threshold="$2"
    local result
    if [[ "$BC_AVAILABLE" == "true" ]]; then
        result=$(echo "$value > $threshold" | bc)
    else
        result=$(awk -v v="$value" -v t="$threshold" 'BEGIN {print (v > t) ? 1 : 0}')
    fi
    echo "Compare: $value > $threshold = $result" >> "$DEBUG_LOG"
    [ "$result" -eq 1 ]
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
            echo "Processing node: $node" >> "$DEBUG_LOG"
            # Check if node is accessible
            if ! oc get node "$node" &> /dev/null; then
                printf "${COLOR_YELLOW}%-40s${COLOR_RESET} ${COLOR_RED}%-10s %-10s %-10s %-10s %-10s %-10s %-10s %-30s${COLOR_RESET}\n" \
                    "$node" "Node inaccessible" "-" "-" "-" "-" "-" "-" "-"
                echo "Node $node inaccessible" >> "$DEBUG_LOG"
                continue
            fi
            # Get memory usage with free -h
            mem_output=$(timeout 30s oc debug node/"$node" -- chroot /host free -h 2>/dev/null | grep Mem: | awk '{print $2, $3, $4, $7}')
            if [[ $? -ne 0 || -z "$mem_output" ]]; then
                printf "${COLOR_YELLOW}%-40s${COLOR_RESET} ${COLOR_RED}%-10s %-10s %-10s %-10s %-10s %-10s %-10s %-30s${COLOR_RESET}\n" \
                    "$node" "Error" "-" "-" "-" "-" "-" "-" "-"
                echo "Memory query failed for $node" >> "$DEBUG_LOG"
                continue
            fi
            read -r mem_total mem_used mem_free mem_avail <<< "$mem_output"
            # Convert memory values to MiB
            mem_total_mib=$(convert_to_mib "$mem_total")
            mem_used_mib=$(convert_to_mib "$mem_used")
            echo "Memory raw for $node: total=$mem_total ($mem_total_mib MiB), used=$mem_used ($mem_used_mib MiB)" >> "$DEBUG_LOG"
            # Calculate memory usage percentage
            if [[ -n "$mem_total_mib" && -n "$mem_used_mib" && "$mem_total_mib" != "0.0" ]]; then
                mem_usage_pct=$(calculate "($mem_used_mib / $mem_total_mib) * 100")
                echo "Memory usage for $node: $mem_used_mib / $mem_total_mib = $mem_usage_pct%" >> "$DEBUG_LOG"
            else
                mem_usage_pct=0.0
                echo "Memory usage for $node: Invalid or zero, set to 0.0%" >> "$DEBUG_LOG"
            fi
            # Get CPU usage with sar -u 1 1
            cpu_output=$(timeout 30s oc debug node/"$node" -- chroot /host sar -u 1 1 2>/dev/null | grep Average | grep -v all | awk '{print $3, $5, $8}')
            if [[ $? -ne 0 || -z "$cpu_output" ]]; then
                # Fallback to top if sar is unavailable
                cpu_output=$(timeout 30s oc debug node/"$node" -- chroot /host top -bn1 2>/dev/null | grep '%Cpu(s)' | awk '{print $2, $4, $8}')
                if [[ $? -ne 0 || -z "$cpu_output" ]]; then
                    printf "${COLOR_YELLOW}%-40s${COLOR_RESET} ${COLOR_WHITE}%-10s %-10s %-10s %-10s ${COLOR_RED}%-10s %-10s %-10s %-30s${COLOR_RESET}\n" \
                        "$node" "$mem_total" "$mem_used" "$mem_free" "$mem_avail" "Error" "-" "-" "-"
                    echo "CPU query failed for $node" >> "$DEBUG_LOG"
                    continue
                fi
            fi
            read -r cpu_user cpu_system cpu_idle <<< "$cpu_output"
            # Calculate total CPU usage (%user + %system)
            cpu_total=$(calculate "$cpu_user + $cpu_system")
            echo "CPU usage for $node: $cpu_user + $cpu_system = $cpu_total%" >> "$DEBUG_LOG"
            # Determine if node has high CPU or memory usage
            notes=""
            node_color="$COLOR_YELLOW"
            if compare_gt "$cpu_total" "$THRESHOLD"; then
                notes="High CPU Usage"
                node_color="$COLOR_RED"
            fi
            if compare_gt "$mem_usage_pct" "$THRESHOLD"; then
                if [[ -n "$notes" ]]; then
                    notes="$notes, High Memory Usage"
                else
                    notes="High Memory Usage"
                    node_color="$COLOR_RED"
                fi
            fi
            found=true
            printf "${node_color}%-40s${COLOR_RESET} ${COLOR_WHITE}%-10s %-10s %-10s %-10s %-10s %-10s %-10s %-30s${COLOR_RESET}\n" \
                "$node" "$mem_total" "$mem_used" "$mem_free" "$mem_avail" "$cpu_user" "$cpu_system" "$cpu_idle" "$notes"
        done
    fi
    echo ""
}

# Flag to track if any data is collected
found=false

# Initialize debug log
echo "Debug log for run at $(date)" > "$DEBUG_LOG"

# List all nodes
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

# Process nodes by role
process_nodes "master" "node-role.kubernetes.io/master="
process_nodes "infra" "node-role.kubernetes.io/infra="
process_nodes "worker" "node-role.kubernetes.io/worker="

# Check if any data was collected
if [[ "$found" == "false" ]]; then
    echo "$(colorize "$COLOR_RED" "No memory or CPU usage data collected from any nodes.")"
    echo "$(colorize "$COLOR_RED" "Troubleshooting steps:")"
    echo "$(colorize "$COLOR_RED" "  - Verify node roles: 'oc get nodes --show-labels'")"
    echo "$(colorize "$COLOR_RED" "  - Check master nodes: 'oc get nodes -l node-role.kubernetes.io/master='")"
    echo "$(colorize "$COLOR_RED" "  - Check infra nodes: 'oc get nodes -l node-role.kubernetes.io/infra='")"
    echo "$(colorize "$COLOR_RED" "  - Check worker nodes: 'oc get nodes -l node-role.kubernetes.io/worker='")"
    echo "$(colorize "$COLOR_RED" "  - Ensure permissions: 'oc auth can-i get nodes' and 'oc auth can-i debug nodes'")"
fi

echo "$(colorize "$COLOR_CYAN" "Debug log saved to $DEBUG_LOG")"
echo "$(colorize "$COLOR_CYAN" "Done.")"
