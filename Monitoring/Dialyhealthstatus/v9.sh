#!/bin/bash

# OpenShift Cluster Health Check Summary Script
# Generates a Pass/Fail report in tabular format for specified health checks
# Run on bastion node with oc client configured

# Configuration
TIMESTAMP=$(date +"%Y%m%d_%H%M")
LOG_DIR="/tmp/oc-health-logs-${TIMESTAMP}"
SUMMARY_LOG="${LOG_DIR}/healthcheck-${TIMESTAMP}.log"
RESULTS_FILE="/tmp/check_results.txt"
CPU_THRESHOLD=80
MEMORY_THRESHOLD=80
DISK_THRESHOLD=70
CERT_THRESHOLD_DAYS=30
API_URL="${API_URL:-https://api.ocp.asd.com:6443}"
MCS_URL="${MCS_URL:-https://api.ocp.asd.com:22623}"
CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "https://console-openshift-console.apps.ocp.sabc.com")

# Proxy settings
export http_proxy="asd"
export https_proxy="${http_proxy}"
export  no_proxy="d"

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Initialize results file
echo "No,Check Name,Status" > "${RESULTS_FILE}"

# ANSI color codes (disabled by default unless USE_COLORS is set)
if [[ "${USE_COLORS}" == "true" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    NC=''
fi

# Array to store results for tabular output
declare -a RESULTS
CHECK_NUMBER=0

# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" >> "${SUMMARY_LOG}"
}

# Function to check oc login
check_oc_login() {
    oc whoami &>/dev/null
    if [[ $? -ne 0 ]]; then
        log_message "ERROR: Not logged in to OpenShift. Please run 'oc login' first."
        exit 1
    fi
}

# Function to print and store result
print_result() {
    local check_name="$1"
    local status="$2"
    ((CHECK_NUMBER++))
    RESULTS+=("${CHECK_NUMBER}|${check_name}|${status}")
    log_message "${check_name}: ${status}"
    echo "${CHECK_NUMBER},${check_name},${status}" >> "${RESULTS_FILE}"
}

# Function to display results in tabular format
display_table() {
    log_message "--------------------------------------------------"
    echo -e "\nCheck Results:\n"
    printf "%-5s %-40s %-10s\n" "No." "Check Name" "Status"
    printf "%-5s %-40s %-10s\n" "----" "----------------------------------------" "----------"
    for result in "${RESULTS[@]}"; do
        IFS='|' read -r number name status <<< "${result}"
        if [[ "${status}" == "Passed" && "${USE_COLORS}" == "true" ]]; then
            printf "%-5s %-40s %s\n" "${number}" "${name}" "${GREEN}${status}${NC}"
        elif [[ "${status}" == "Failed" && "${USE_COLORS}" == "true" ]]; then
            printf "%-5s %-40s %s\n" "${number}" "${name}" "${RED}${status}${NC}"
        else
            printf "%-5s %-40s %s\n" "${number}" "${name}" "${status}"
        fi
    done
    cat "${RESULTS_FILE}" | grep -E '^[0-9]+,' >> "${SUMMARY_LOG}"
}

# Check 1: Cluster Operators
check_cluster_operators() {
    local result=$(oc get co --no-headers | awk '($3 != "True" || $4 != "False" || $5 != "False") {print $0}')
    if [[ -z "${result}" ]]; then
        print_result "Cluster Operators" "Passed"
    else
        print_result "Cluster Operators" "Failed"
        log_message "Failing Cluster Operators: ${result}"
    fi
}

# Check 2: Node Readiness
check_node_readiness() {
    local result=$(oc get nodes --no-headers | grep -v Ready)
    if [[ -z "${result}" ]]; then
        print_result "Node Readiness" "Passed"
    else
        print_result "Node Readiness" "Failed"
        log_message "Non-ready Nodes: ${result}"
    fi
}

# Check 3: Node CPU Usage
check_node_cpu() {
    local top_output=$(oc adm top nodes --no-headers)
    log_message "Node CPU Usage Raw Output:\n${top_output}"
    local result=$(echo "$top_output" | awk -v thresh="${CPU_THRESHOLD}" '{gsub("%","",$3); if ($3+0 > thresh) print $1, $3}')
    log_message "Node CPU Usage Parsed (threshold ${CPU_THRESHOLD}%): ${result}"
    if [[ -z "${result}" ]]; then
        print_result "Node CPU Usage (<${CPU_THRESHOLD}%)" "Passed"
    else
        print_result "Node CPU Usage (<${CPU_THRESHOLD}%)" "Failed"
        log_message "Nodes exceeding CPU threshold: ${result}"
    fi
}

# Check 4: Node Memory Usage
check_node_memory() {
    local top_output=$(oc adm top nodes --no-headers)
    log_message "Node Memory Usage Raw Output:\n${top_output}"
    local result=$(echo "$top_output" | awk -v thresh="${MEMORY_THRESHOLD}" '{gsub("%","",$5); if ($5+0 > thresh) print $1, $5}')
    log_message "Node Memory Usage Parsed (threshold ${MEMORY_THRESHOLD}%): ${result}"
    if [[ -z "${result}" ]]; then
        print_result "Node Memory Usage (<${MEMORY_THRESHOLD}%)" "Passed"
    else
        print_result "Node Memory Usage (<${MEMORY_THRESHOLD}%)" "Failed"
        log_message "Nodes exceeding Memory threshold: ${result}"
    fi
}

# Check 5: SSL Certificate Expiry
check_ssl_certificates() {
    if ! command -v openssl &>/dev/null; then
        print_result "SSL Certificate Expiry (<${CERT_THRESHOLD_DAYS} days)" "Failed"
        log_message "SSL Certificate check failed: openssl not installed"
        return
    fi

    local EXCLUDED_NAMESPACES="openshift-compliance openshift-kube-apiserver openshift-kube-apiserver-operator openshift-kube-controller-manager-operator openshift-kube-controller-manager openshift-kube-scheduler openshift-operator-lifecycle-manager openshift-config-managed"
    local TEMP_OUTPUT=$(mktemp)
    local DETAILED_LOG="${LOG_DIR}/ssl_cert_check.log"
    local result=""

    # Collect cert info
    local raw_output
    raw_output=$(oc get secrets -A -o go-template='{{range .items}}{{if eq .type "kubernetes.io/tls"}}{{.metadata.namespace}}{{" "}}{{.metadata.name}}{{" "}}{{index .data "tls.crt"}}{{"\n"}}{{end}}{{end}}')

    # Process secrets, excluding namespaces individually
    echo "$raw_output" | while read -r namespace name cert; do
        # Skip excluded namespaces
        case "$namespace" in
            openshift-compliance|openshift-kube-apiserver|openshift-kube-apiserver-operator|openshift-kube-controller-manager-operator|openshift-kube-controller-manager|openshift-kube-scheduler|openshift-operator-lifecycle-manager|openshift-config-managed)
                continue
                ;;
        esac
        if [[ -z "$namespace" || -z "$name" || -z "$cert" ]]; then
            continue
        fi
        local start_date=$(echo "$cert" | base64 -d | openssl x509 -noout -startdate 2>>"${SUMMARY_LOG}" | sed 's/^notBefore=//')
        local expiry_date=$(echo "$cert" | base64 -d | openssl x509 -noout -enddate 2>>"${SUMMARY_LOG}" | sed 's/^notAfter=//')
        if [[ -z "$start_date" || -z "$expiry_date" ]]; then
            continue
        fi
        local expiry_ts=$(date -d "$expiry_date" +%s 2>>"${SUMMARY_LOG}")
        local now_ts=$(date +%s)
        if [[ -z "$expiry_ts" || -z "$now_ts" ]]; then
            continue
        fi
        local validity_days=$(( (expiry_ts - now_ts) / 86400 ))
        if [[ -n "$validity_days" && "$validity_days" -lt "$CERT_THRESHOLD_DAYS" ]]; then
            echo -e "$namespace\t$name\t$start_date\t$expiry_date\t$validity_days" >> "$TEMP_OUTPUT"
            result="failed"
        fi
    done

    if [ -s "$TEMP_OUTPUT" ]; then
        print_result "SSL Certificate Expiry (<${CERT_THRESHOLD_DAYS} days)" "Failed"
        mv "$TEMP_OUTPUT" "$DETAILED_LOG"
        log_message "Certificates expiring within ${CERT_THRESHOLD_DAYS} days saved to ${DETAILED_LOG}"
        cat "$DETAILED_LOG" >> "${SUMMARY_LOG}"
    else
        print_result "SSL Certificate Expiry (<${CERT_THRESHOLD_DAYS} days)" "Passed"
        log_message "No certificates expiring within ${CERT_THRESHOLD_DAYS} days"
    fi
}

# Check 6: Platform Namespace Pod Status
check_platform_namespaces() {
    local result=$(oc get pods --all-namespaces --no-headers | awk '$4 != "Running" && $4 != "Completed" {count[$1]++} END {for (ns in count) if (ns ~ /^(openshift-|kube-)/) print ns, count[ns]}')
    local failed_pods=$(oc get pods --all-namespaces --no-headers | awk '$4 != "Running" && $4 != "Completed" && $1 ~ /^(openshift-|kube-)/ {print $1, $2, $4}')
    if [[ -z "${result}" ]]; then
        print_result "Platform Namespace Pod Status" "Passed"
    else
        print_result "Platform Namespace Pod Status" "Failed"
        log_message "Failing Platform Namespace Pods (namespace pod status):\n${failed_pods}"
    fi
}

# Check 7: Non-Platform Pod Status
check_non_platform_pods() {
    local result=$(oc get pods --all-namespaces --no-headers | awk '$4 != "Running" && $4 != "Completed" && $1 !~ /^(openshift-|kube-)/ {print $0}')
    if [[ -z "${result}" ]]; then
        print_result "Non-Platform Pod Status" "Passed"
    else
        print_result "Non-Platform Pod Status" "Failed"
        log_message "Failing Non-Platform Pods: ${result}"
    fi
}

# Check 8: API Server Health
check_api_server() {
    local result=$(curl --noproxy '*' -ks "${API_URL}/readyz" 2>/dev/null)
    if [[ "${result}" == "ok" ]]; then
        print_result "API Server Health" "Passed"
    else
        print_result "API Server Health" "Failed"
        log_message "API Server Health check failed: ${result}"
    fi
}

# Check 9: Ingress Controller Health
check_ingress_controller() {
    local http_code=$(curl --noproxy '*' -ks -o /dev/null -w "%{http_code}" "${CONSOLE_URL}" 2>/dev/null)
    if [[ "${http_code}" == "200" ]]; then
        print_result "Ingress Controller Health" "Passed"
    else
        print_result "Ingress Controller Health" "Failed"
        log_message "Ingress Controller Health check failed with HTTP code: ${http_code}"
    fi
}

# Check 10: Machine Config Server
check_machine_config_server() {
    local master_result=$(curl --noproxy '*' -ks "${MCS_URL}/config/master" 2>/dev/null | grep -q '"ignition"' && echo "Pass")
    local worker_result=$(curl --noproxy '*' -ks "${MCS_URL}/config/worker" 2>/dev/null | grep -q '"ignition"' && echo "Pass")
    if [[ "${master_result}" == "Pass" && "${worker_result}" == "Pass" ]]; then
        print_result "Machine Config Server" "Passed"
    else
        print_result "Machine Config Server" "Failed"
        log_message "Machine Config Server check failed - Master: ${master_result}, Worker: ${worker_result}"
    fi
}

# Check 11: MachineConfigPool
check_mcp() {
    local result=$(oc get mcp --no-headers | awk '($3 != "True" || $4 != "False" || $5 != "False") {print $0}')
    if [[ -z "${result}" ]]; then
        print_result "MachineConfigPool" "Passed"
    else
        print_result "MachineConfigPool" "Failed"
        log_message "Failing MachineConfigPools: ${result}"
    fi
}

# Check 12: Monitoring Stack
check_monitoring_stack() {
    local result=$(oc get pods -n openshift-monitoring --no-headers | grep -E 'prometheus-k8s|alertmanager-main|grafana' | grep -v Running)
    if [[ -z "${result}" ]]; then
        print_result "Monitoring Stack" "Passed"
    else
        print_result "Monitoring Stack" "Failed"
        log_message "Failing Monitoring Stack Pods: ${result}"
    fi
}

# Check 13: Etcd Cluster Health
check_etcd_health() {
    local pod_name=$(oc get pods -n openshift-etcd -l app=etcd --field-selector="status.phase==Running" -o jsonpath="{.items[0].metadata.name}")
    local result=$(oc exec -n openshift-etcd -c etcdctl "${pod_name}" -- sh -c "etcdctl endpoint health --cluster" 2>/dev/null | grep -v healthy)
    if [[ -z "${result}" ]]; then
        print_result "Etcd Cluster Health" "Passed"
    else
        print_result "Etcd Cluster Health" "Failed"
        log_message "Etcd Cluster Health check failed: ${result}"
    fi
}

# Check 14: Authentication
check_authentication() {
    local result=$(oc get pods -n openshift-authentication --no-headers | grep -v Running)
    if [[ -z "${result}" ]]; then
        print_result "Authentication" "Passed"
    else
        print_result "Authentication" "Failed"
        log_message "Failing Authentication Pods: ${result}"
    fi
}

# Check 15: Cluster Version
check_cluster_version() {
    local result=$(oc get clusterversion --no-headers | awk '$3 != "True" || $4 != "False" {print $0}')
    if [[ -z "${result}" ]]; then
        print_result "Cluster Version" "Passed"
    else
        print_result "Cluster Version" "Failed"
        log_message "Failing Cluster Version: ${result}"
    fi
}

# Check 16: PVC and PV Health
check_pvc_pv() {
    local result=$(oc get pvc --all-namespaces --no-headers | grep -iv Bound)
    if [[ -z "${result}" ]]; then
        print_result "PVC and PV Health" "Passed"
    else
        print_result "PVC and PV Health" "Failed"
        log_message "Failing PVCs: ${result}"
    fi
}

# Check 17: Control Plane
check_control_plane() {
    local result=""
    for ns in openshift-kube-apiserver openshift-kube-scheduler openshift-kube-controller-manager openshift-etcd; do
        result+=$(oc get pods -n "${ns}" --no-headers | grep -vE '(Running|Completed)' || true)
        result+=$'\n'
    done
    if [[ -z "${result//[$'\n']}" ]]; then
        print_result "Control Plane" "Passed"
    else
        print_result "Control Plane" "Failed"
        log_message "Failing Control Plane Pods: ${result}"
    fi
}

# Main execution
log_message "Starting OpenShift Cluster Health Check Summary"
check_oc_login
log_message "--------------------------------------------------"

# Execute checks in fixed order
check_cluster_operators
check_node_readiness
check_node_cpu
check_node_memory
check_ssl_certificates
check_platform_namespaces
check_non_platform_pods
check_api_server
check_ingress_controller
check_machine_config_server
check_mcp
check_monitoring_stack
check_etcd_health
check_authentication
check_cluster_version
check_pvc_pv
check_control_plane

display_table
log_message "--------------------------------------------------"
log_message "Health check summary completed. Log saved to ${SUMMARY_LOG}"
