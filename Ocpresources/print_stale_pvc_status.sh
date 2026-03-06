###This Bash script is designed to scan OpenShift PersistentVolumes (PVs) in the "Released" state, check whether their associated PVCs (PersistentVolumeClaims) still exist or have been reused, and then log the results both to a CSV file and to the terminal.
#!/bin/bash

# CSV Output File
datetime=$(date +"%Y-%m-%d_%H-%M-%S")
csv_file="volume_release_mapping_$datetime.csv"

# Create a CSV file with headers
echo "OLD_PV,VOLUME_ID(OLD),STORAGE_CLASS,OLD_PVC_NAMESPACE,OLD_PVC_NAME,STATUS,NEW_PV,VOLUME_ID(NEW)" > "$csv_file"

# Print headers with proper alignment for terminal
printf "%-30s %-25s %-20s %-25s %-30s %-20s %-25s %-25s\n" \
  "OLD_PV" "VOLUME_ID(OLD)" "STORAGE_CLASS" "OLD_PVC_NAMESPACE" "OLD_PVC_NAME" "STATUS" "NEW_PV" "VOLUME_ID(NEW)"

# Get all Released PVs
for pv in $(oc get pv --no-headers | awk '$5 == "Released" {print $1}'); do
  pvc_ns=$(oc get pv "$pv" -o jsonpath='{.spec.claimRef.namespace}' 2>/dev/null)
  pvc_name=$(oc get pv "$pv" -o jsonpath='{.spec.claimRef.name}' 2>/dev/null)
  sc=$(oc get pv "$pv" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
  volume_id_old=$(oc get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)

  # Check if PVC details are missing
  if [ -z "$pvc_ns" ] || [ -z "$pvc_name" ]; then
    printf "%-30s %-25s %-20s %-25s %-30s %-20s %-25s %-25s\n" \
      "$pv" "$volume_id_old" "$sc" "-" "-" "Missing claimRef" "-" "-"
    echo "$pv,$volume_id_old,$sc,-,-,Missing claimRef,-,-" >> "$csv_file"
    continue
  fi

  # Check if PVC exists
  if oc get pvc "$pvc_name" -n "$pvc_ns" &>/dev/null; then
    new_pv=$(oc get pvc "$pvc_name" -n "$pvc_ns" -o jsonpath='{.spec.volumeName}')
    volume_id_new=$(oc get pv "$new_pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)
    # Output data if PVC is reused
    printf "%-30s %-25s %-20s %-25s %-30s %-20s %-25s %-25s\n" \
      "$pv" "$volume_id_old" "$sc" "$pvc_ns" "$pvc_name" "PVC_REUSED" "$new_pv" "$volume_id_new"
    echo "$pv,$volume_id_old,$sc,$pvc_ns,$pvc_name,PVC_REUSED,$new_pv,$volume_id_new" >> "$csv_file"
  else
    # Output data if PVC is safe to delete
    printf "%-30s %-25s %-20s %-25s %-30s %-20s %-25s %-25s\n" \
      "$pv" "$volume_id_old" "$sc" "$pvc_ns" "$pvc_name" "SAFE_TO_DELETE" "-" "-"
    echo "$pv,$volume_id_old,$sc,$pvc_ns,$pvc_name,SAFE_TO_DELETE,-,-" >> "$csv_file"
  fi
done

echo "CSV file created: $csv_file"
