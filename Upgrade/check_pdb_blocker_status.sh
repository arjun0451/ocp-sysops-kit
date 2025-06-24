#!/bin/bash

# Script to find PDBs with disruptionsAllowed=0 in OpenShift,
# list associated pods, and identify the nodes they are running on, with colorized output.

# ANSI color codes
COLOR_CYAN="\e[36m"
COLOR_YELLOW="\e[33m"
COLOR_GREEN="\e[32m"
COLOR_RED="\e[31m"
COLOR_BLUE="\e[34m"
COLOR_WHITE="\e[0m"
COLOR_RESET="\e[0m"

# Check if terminal supports colors
if [[ -t 1 && $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    USE_COLORS=true
else
    USE_COLORS=false
    COLOR_CYAN=""
    COLOR_YELLOW=""
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_BLUE=""
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

# Ensure jq is available
if ! command -v jq &> /dev/null; then
    echo "$(colorize "$COLOR_RED" "Error: 'jq' command not found. Please install jq to parse JSON output.")"
    exit 1
fi

# Check if user is logged into OpenShift
if ! oc whoami &> /dev/null; then
    echo "$(colorize "$COLOR_RED" "Error: Not logged into OpenShift. Please run 'oc login' first.")"
    exit 1
fi

echo "$(colorize "$COLOR_CYAN" "Checking for PDBs with disruptionsAllowed = 0 (potential blockers)...")"
echo "$(colorize "$COLOR_CYAN" "======================================================================")"
echo ""

# Print table header for PDB details
printf "${COLOR_CYAN}%-35s %-45s %-14s %-17s %-16s %-17s %-20s${COLOR_RESET}\n" "NAMESPACE" "PDB NAME" "minAvailable" "maxUnavailable" "currentHealthy" "desiredHealthy" "disruptionsAllowed"
printf "${COLOR_CYAN}%s${COLOR_RESET}\n" "--------------------------------------------------------------------------------------------------------------------------------------------------------------"

# Initialize found flag
found=false

# Get all PDBs with disruptionsAllowed=0 and process them
while IFS=$'\t' read -r ns name min max cur des dis selector; do
    # Set found flag to true since we have a matching PDB
    found=true

    # Print PDB details with colors
    printf "${COLOR_YELLOW}%-35s${COLOR_RESET} ${COLOR_YELLOW}%-45s${COLOR_RESET} ${COLOR_WHITE}%-14s${COLOR_RESET} ${COLOR_WHITE}%-17s${COLOR_RESET} ${COLOR_WHITE}%-16s${COLOR_RESET} ${COLOR_WHITE}%-17s${COLOR_RESET} ${COLOR_WHITE}%-20s${COLOR_RESET}\n" "$ns" "$name" "$min" "$max" "$cur" "$des" "$dis"

    # Process pods if selector is not empty
    if [[ -n "$selector" && "$selector" != "{}" ]]; then
        echo "$(colorize "$COLOR_GREEN" "  Pods associated with PDB '$name' in namespace '$ns':")"
        echo "$(colorize "$COLOR_BLUE" "    Selector: $selector")"

        # Get pods matching the selector
        pods=$(oc get pods -n "$ns" --selector="$selector" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

        if [[ -z "$pods" ]]; then
            echo "$(colorize "$COLOR_RED" "    No pods found matching the selector.")"
        else
            # Print table header for pods
            printf "${COLOR_CYAN}    %-40s %-40s${COLOR_RESET}\n" "POD NAME" "NODE"
            printf "${COLOR_CYAN}    %s${COLOR_RESET}\n" "--------------------------------------------------------------------------------"

            # Iterate through pods to get their nodes
            while IFS= read -r pod; do
                if [[ -n "$pod" ]]; then
                    node=$(oc get pod "$pod" -n "$ns" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
                    if [[ -z "$node" ]]; then
                        node="Not scheduled"
                    fi
                    printf "${COLOR_GREEN}    %-40s %-40s${COLOR_RESET}\n" "$pod" "$node"
                fi
            done <<< "$pods"
        fi
    else
        echo "$(colorize "$COLOR_RED" "  No selector labels found for PDB '$name' in namespace '$ns'.")"
    fi
    echo ""
done < <(oc get pdb -A -o json | jq -r '
  .items[] |
  {
    namespace: .metadata.namespace,
    name: .metadata.name,
    minAvailable: (.spec.minAvailable // "null"),
    maxUnavailable: (.spec.maxUnavailable // "null"),
    currentHealthy: (.status.currentHealthy // 0),
    desiredHealthy: (.status.desiredHealthy // 0),
    disruptionsAllowed: (.status.disruptionsAllowed // 0),
    selector: (.spec.selector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(","))
  } |
  select(.disruptionsAllowed == 0) |
  "\(.namespace)\t\(.name)\t\(.minAvailable)\t\(.maxUnavailable)\t\(.currentHealthy)\t\(.desiredHealthy)\t\(.disruptionsAllowed)\t\(.selector)"
')

# Check if any PDBs were found
if [[ "$found" == "false" ]]; then
    echo "$(colorize "$COLOR_RED" "No PDBs found with disruptionsAllowed=0.")"
fi

echo "$(colorize "$COLOR_BLUE" "Done.")"
