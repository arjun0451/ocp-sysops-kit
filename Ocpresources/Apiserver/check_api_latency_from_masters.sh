#!/bin/bash
# --------------------------------------------------------------------
# Script: check_api_latency_from_masters.sh
# Purpose: Measure OpenShift API connectivity timings from each master node
# --------------------------------------------------------------------

# Set your API endpoint (e.g. api.<cluster>.<domain>:6443)
OCP_URL="api.ocpp1.ocp.tsa:6443"

# Get all master nodes dynamically
MASTER_NODES=$(oc get nodes -l node-role.kubernetes.io/master= -o name | cut -d'/' -f2)

echo "Testing connectivity to https://$OCP_URL from all master nodes..."
echo "===================================================================="

for NODE in $MASTER_NODES; do
  echo ""
  echo "[$NODE]"
  echo "--------------------------------------------------------------------"

  # Detailed timing breakdown
  echo ">> Detailed timing metrics:"
  oc debug node/$NODE --quiet -- chroot /host bash -c "
    curl -k -s -o /dev/null -w 'DNS lookup: %{time_namelookup}s\nConnect: %{time_connect}s\nTLS handshake: %{time_appconnect}s\nStart transfer: %{time_starttransfer}s\nTotal: %{time_total}s\n' https://$OCP_URL
  " | awk '
    /DNS lookup:/ {printf "DNS lookup: %.3f ms\n", $3*1000}
    /Connect:/ {printf "Connect: %.3f ms\n", $2*1000}
    /TLS handshake:/ {printf "TLS handshake: %.3f ms\n", $3*1000}
    /Start transfer:/ {printf "Start transfer: %.3f ms\n", $3*1000}
    /Total:/ {printf "Total: %.3f ms\n", $2*1000}
  '

  echo ""
  echo ">> Simple connect time only:"
  oc debug node/$NODE --quiet -- chroot /host bash -c "
    curl -k -s -o /dev/null -w '%{time_connect}\n' https://$OCP_URL
  " | awk '{printf "Connect time only: %.3f ms\n", $1*1000}'

  echo "--------------------------------------------------------------------"
done

echo ""
echo "===================================================================="
echo "Connectivity test complete."
