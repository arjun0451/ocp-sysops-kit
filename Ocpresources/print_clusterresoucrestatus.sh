#!/bin/bash

# Function to convert CPU to millicores
convert_cpu_to_millicores() {
  local cpu=$1
  if [[ $cpu =~ m$ ]]; then
    echo ${cpu%m}
  else
    echo $((${cpu} * 1000))
  fi
}

# Function to convert memory units to MiB
convert_memory_to_mib() {
  local memory=$1
  if [[ $memory =~ Gi$ ]]; then
    echo $((${memory%Gi} * 1024))
  elif [[ $memory =~ Mi$ ]]; then
    echo ${memory%Mi}
  elif [[ $memory =~ Ki$ ]]; then
    echo $((${memory%Ki} / 1024))
  else
    echo $memory  # Return the memory value as-is if no unit is found
  fi
}

# Function to convert storage units to MiB
convert_storage_to_mib() {
  local storage=$1
  if [[ $storage =~ Gi$ ]]; then
    echo $((${storage%Gi} * 1024))
  elif [[ $storage =~ Mi$ ]]; then
    echo ${storage%Mi}
  elif [[ $storage =~ Ki$ ]]; then
    echo $((${storage%Ki} / 1024))
  else
    echo $storage  # Return the storage value as-is if no unit is found
  fi
}

# Function to parse and extract storage requests
parse_storage_requests() {
  local rq_name=$1
  local ns=$2
  local storage_field=$3

  storage=$(oc get resourcequota $rq_name -n $ns -o=jsonpath="{.status.hard.${storage_field}}")
  if [[ ! -z "$storage" ]]; then
    storage=$(convert_storage_to_mib $storage)
    echo $storage
  else
    echo 0
  fi
}

# Initialize variables for the final summary in Report-3
total_cpu=0
total_memory=0
total_allocatable_cpu=0
total_allocatable_memory=0
total_rq_cpu=0
total_rq_memory=0
total_rq_thin_storage=0
total_rq_isilon_storage=0

# Files for CSV reports
node_csv="node_report.csv"
rq_csv="resource_quota_report.csv"
summary_csv="summary_report.csv"

# Create CSV files and add headers
echo "Node Name,Node IP,Actual CPU (cores),Actual Memory (MiB),Allocatable CPU (m),Allocatable Memory (MiB),Node Status" > $node_csv
echo "Namespace,ResourceQuota Name,CPU Requests (m),Memory Requests (MiB),Thin Storage (MiB),Isilon Storage (MiB)" > $rq_csv
echo "Report Type,Total Available CPU on Worker Nodes (m),Total Available Memory on Worker Nodes (MiB),Total Assigned CPU via ResourceQuotas (m),Total Assigned Memory via ResourceQuotas (MiB),Total Assigned Thin Storage (MiB),Total Assigned Isilon Storage (MiB),Total Free CPU Quota Available (m),Total Free Memory Quota Available (MiB)" > $summary_csv

# Report-1: Node Report
echo "-------------------------------"
echo "Report - 1: Node Report"
echo "-------------------------------"
printf "%-20s %-20s %-20s %-20s %-20s %-20s %-20s\n" "Node Name" "Node IP" "Actual CPU (cores)" "Actual Memory (MiB)" "Allocatable CPU (m)" "Allocatable Memory (MiB)" "Node Status"

for node in $(oc get nodes --no-headers | awk '{print $1}'); do
  node_ip=$(oc get node $node -o=jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  allocatable_cpu=$(oc get node $node -o=jsonpath='{.status.allocatable.cpu}')
  allocatable_memory=$(oc get node $node -o=jsonpath='{.status.allocatable.memory}')
  actual_cpu=$(oc describe node $node | grep -m1 "cpu:" | awk '{print $2}')
  actual_memory=$(oc describe node $node | grep -m1 "memory:" | awk '{print $2}')

  if [[ $node =~ master ]]; then
    node_status="Master Node"
  else
    node_status="Worker Node"
    total_allocatable_cpu=$(($total_allocatable_cpu + $(convert_cpu_to_millicores $allocatable_cpu)))
    total_allocatable_memory=$(($total_allocatable_memory + $(convert_memory_to_mib $allocatable_memory)))
  fi

  printf "%-20s %-20s %-20s %-20s %-20s %-20s %-20s\n" "$node" "$node_ip" "$actual_cpu" "$actual_memory" "$allocatable_cpu" "$allocatable_memory" "$node_status"
  echo "$node,$node_ip,$actual_cpu,$(convert_memory_to_mib $actual_memory),$(convert_cpu_to_millicores $allocatable_cpu),$(convert_memory_to_mib $allocatable_memory),$node_status" >> $node_csv
done

# Report-2: Resource Quota Report
echo "-------------------------------"
echo "Report - 2: Resource Quota Report"
echo "-------------------------------"
printf "%-20s %-25s %-20s %-20s %-20s %-20s\n" "Namespace" "ResourceQuota Name" "CPU Requests (m)" "Memory Requests (MiB)" "Thin Storage (MiB)" "Isilon Storage (MiB)"

for ns in $(oc get namespaces --no-headers | awk '{print $1}' | grep -v '^openshift-\|^kube-\|^default$'); do
  rq_list=$(oc get resourcequota -n $ns --no-headers -o custom-columns=:.metadata.name)

  if [ -z "$rq_list" ]; then
    printf "%-20s %-25s %-20s %-20s %-20s %-20s\n" "$ns" "N/A" "0" "0" "0" "0"
    echo "$ns,N/A,0,0,0,0" >> $rq_csv
  else
    while IFS= read -r rq_name; do
      rq_cpu=$(oc get resourcequota $rq_name -n $ns -o=jsonpath='{.status.hard.requests\.cpu}')
      rq_memory=$(oc get resourcequota $rq_name -n $ns -o=jsonpath='{.status.hard.requests\.memory}')
      rq_thin_storage=$(parse_storage_requests $rq_name $ns "thin.storageclass.storage.k8s.io/requests.storage")
      rq_isilon_storage=$(parse_storage_requests $rq_name $ns "Isilon.storageclass.storage.k8s.io/requests.storage")
#the below hashed is the right parse 
#req_isilon=$(oc get quota -o jsonpath='{.items[*].status.hard.isilon\.storageclass\.storage\.k8s\.io/requests\.storage}')

      if [[ ! -z "$rq_cpu" ]]; then
        rq_cpu=$(convert_cpu_to_millicores $rq_cpu)
        total_rq_cpu=$(($total_rq_cpu + $rq_cpu))
      else
        rq_cpu=0
      fi

      if [[ ! -z "$rq_memory" ]]; then
        rq_memory=$(convert_memory_to_mib $rq_memory)
        total_rq_memory=$(($total_rq_memory + $rq_memory))
      else
        rq_memory=0
      fi

      total_rq_thin_storage=$(($total_rq_thin_storage + $rq_thin_storage))
      total_rq_isilon_storage=$(($total_rq_isilon_storage + $rq_isilon_storage))

      printf "%-20s %-25s %-20s %-20s %-20s %-20s\n" "$ns" "$rq_name" "$rq_cpu" "$rq_memory" "$rq_thin_storage" "$rq_isilon_storage"
      echo "$ns,$rq_name,$rq_cpu,$rq_memory,$rq_thin_storage,$rq_isilon_storage" >> $rq_csv
    done <<< "$rq_list"
  fi
done

# Print the grand totals for Report-2
echo "-------------------------------"
printf "%-20s %-25s %-20s %-20s %-20s %-20s\n" "Grand Total" "" "$total_rq_cpu" "$total_rq_memory" "$total_rq_thin_storage" "$total_rq_isilon_storage"
echo "-------------------------------"
echo "Grand Total,,,$total_rq_cpu,$total_rq_memory,$total_rq_thin_storage,$total_rq_isilon_storage" >> $rq_csv

# Report-3: Summary Report
echo "-------------------------------"
echo "Report - 3: Cluster Utilization Summary"
echo "-------------------------------"
printf "%-35s %-20s\n" "Total Available CPU on Worker Nodes (m)" "$total_allocatable_cpu"
printf "%-35s %-20s\n" "Total Available Memory on Worker Nodes (MiB)" "$total_allocatable_memory"
printf "%-35s %-20s\n" "Total Assigned CPU via ResourceQuotas (m)" "$total_rq_cpu"
printf "%-35s %-20s\n" "Total Assigned Memory via ResourceQuotas (MiB)" "$total_rq_memory"
printf "%-35s %-20s\n" "Total Assigned Thin Storage (MiB)" "$total_rq_thin_storage"
printf "%-35s %-20s\n" "Total Assigned Isilon Storage (MiB)" "$total_rq_isilon_storage"
printf "%-35s %-20s\n" "Total Free CPU Quota Available (m)"
printf "%-35s %-20s\n" "Total Free CPU Quota Available (m)" "$(($total_allocatable_cpu - $total_rq_cpu))"
printf "%-35s %-20s\n" "Total Free Memory Quota Available (MiB)" "$(($total_allocatable_memory - $total_rq_memory))"

# Append the summary to the CSV report
echo "Summary,$total_allocatable_cpu,$total_allocatable_memory,$total_rq_cpu,$total_rq_memory,$total_rq_thin_storage,$total_rq_isilon_storage,$(($total_allocatable_cpu - $total_rq_cpu)),$(($total_allocatable_memory - $total_rq_memory))" >> $summary_csv

echo "-------------------------------"
echo "Reports have been generated:"
echo "1. Node report: $node_csv"
echo "2. Resource quota report: $rq_csv"
echo "3. Summary report: $summary_csv"
echo "-------------------------------"