### Print the Promethueus metric report
# Enhancing output headers using ANSI color codes and boxed formatting for clear sections
#!/bin/bash

# Requires: oc, curl, jq

# Colors and formatting
BOLD=$(tput bold)
NORMAL=$(tput sgr0)
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
RED="\033[1;31m"
RESET="\033[0m"

print_section() {
  local title="$1"
  local color="${2:-$CYAN}"
  local border="════════════════════════════════════════════════════"
  echo -e "\n${color}${BOLD}╔═${border}╗"
  printf "${color}${BOLD}║ %-50s  ║\n" "$title"
  echo -e "╚═${border}╝${RESET}${NORMAL}"
}

# Get OpenShift token and Prometheus route
TOKEN=$(oc whoami -t)
HOST=$(oc -n openshift-monitoring get route prometheus-k8s -o jsonpath='{.spec.host}')
PROM_URL="https://$HOST/api/v1/query"

# Function to run a PromQL query
run_query() {
  local query="$1"
  curl -s -k -H "Authorization: Bearer $TOKEN" "$PROM_URL" \
    --data-urlencode "query=$query"
}

# PVC usage > 70%
print_pvc_usage() {
  print_section "PVC usage over 70%" "$YELLOW"
  QUERY='(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100 > 70'
  run_query "$QUERY" | jq -r '.data.result[] | "\(.metric.namespace) | \(.metric.persistentvolumeclaim) | \(.value[1])%"'
}

# ETCD DB size
print_etcd_db_size() {
  print_section "ETCD database size in bytes" "$CYAN"
  QUERY='etcd_mvcc_db_total_size_in_bytes{job=~".*etcd.*", job="etcd"}'
  run_query "$QUERY" | jq -r '.data.result[] | "\(.metric.instance) | \(.value[1]) bytes"'
}

# ETCD RTT (p99)
print_etcd_rtt() {
  print_section "ETCD peer round-trip time (p99, 5m, in ms)" "$CYAN"
  QUERY='histogram_quantile(0.99, sum by (instance, le) (rate(etcd_network_peer_round_trip_time_seconds_bucket{job=~".*etcd.*", job="etcd"}[5m]))) * 1000'
  run_query "$QUERY" | jq -r '.data.result[] | "\(.metric.instance) | \(.value[1]) ms"'
}

# OOMKilled
print_oom_killed() {
  print_section "Pods terminated due to OOMKilled (last 1h)" "$RED"
  QUERY='count_over_time(kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}[1h])'
  run_query "$QUERY" | jq -r '.data.result[] | "\(.metric.namespace) | \(.metric.pod) | \(.metric.container) | Count: \(.value[1])"'
}

# CPU usage top 10
print_top_cpu_usage() {
  print_section "Top10 pods using >=90% of their CPU limit(last 5m)" "$GREEN"
  QUERY='(
    sum(rate(container_cpu_usage_seconds_total{container!=""}[5m])) by (pod, namespace)
    /
    sum(kube_pod_container_resource_limits{resource="cpu", unit="core"}) by (pod, namespace)
  ) * 100'
  run_query "$QUERY" | jq -r '
    .data.result
    | map({
        ns: .metric.namespace,
        pod: .metric.pod,
        usage_pct: (.value[1] | tonumber)
      })
    | map(select(.usage_pct >= 90))
    | sort_by(-.usage_pct)
    | .[:10]
    | [["Namespace", "Pod", "CPU Usage (%)"]] + (map([.ns, .pod, (.usage_pct | tostring)]))
    | .[] | @tsv
  ' | column -t
}

# Memory usage top 10
print_high_memory_usage() {
  print_section "Top 10 Pods using >80% of memory limit" "$YELLOW"
  QUERY='(
    sum(container_memory_working_set_bytes{container!=""}) by (pod, namespace)
    /
    sum(kube_pod_container_resource_limits{resource="memory", unit="byte"}) by (pod, namespace)
  )'
  run_query "$QUERY" | jq -r '
    .data.result
    | map({
        ns: .metric.namespace,
        pod: .metric.pod,
        usage: (.value[1] | tonumber)
      })
    | map(select(.usage > 0.8))
    | sort_by(-.usage)
    | .[:10]
    | [["Namespace", "Pod", "Memory Usage Ratio"]] + (map([.ns, .pod, (.usage | tostring)]))
    | .[] | @tsv
  ' | column -t
}

# Alert summary
print_alert_summary() {
  print_section "Active Alerts Summary (Firing/Pending)" "$RED"
  QUERY='sum by (alertname, namespace, severity) (ALERTS{alertstate=~"firing|pending", severity=~"critical|warning"})'
  run_query "$QUERY" | jq -r '
    .data.result
    | [["Alert Name", "Namespace", "Severity", "Count"]] +
      (map([.metric.alertname, .metric.namespace // "N/A", .metric.severity, .value[1]]))
    | .[] | @tsv
  ' | column -t
}

# Run all checks
print_pvc_usage
print_etcd_db_size
print_etcd_rtt
print_oom_killed
print_top_cpu_usage
print_high_memory_usage
print_alert_summary

echo -e "\n${GREEN}${BOLD}✅ Prometheus cluster checks complete.${RESET}${NORMAL}"
