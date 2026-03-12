#!/bin/bash

datetime=$(date +"%Y-%m-%d_%H-%M-%S")
csv_file="volume_release_mapping_$datetime.csv"

echo "OLD_PV,VOLUME_TYPE,VOLUME_ID(OLD),OLD_CAPACITY,STORAGE_CLASS,OLD_PVC_NAMESPACE,OLD_PVC_NAME,STATUS,NEW_PV,VOLUME_ID(NEW),NEW_CAPACITY" > "$csv_file"

printf "%-30s %-10s %-35s %-12s %-20s %-25s %-25s %-18s %-30s %-35s %-12s\n" \
"OLD_PV" "TYPE" "VOLUME_ID(OLD)" "OLD_CAP" "STORAGE_CLASS" "OLD_PVC_NAMESPACE" "OLD_PVC_NAME" "STATUS" "NEW_PV" "VOLUME_ID(NEW)" "NEW_CAP"

# Summary counters
total_released=0
safe_delete_count=0
reused_count=0
missing_claim=0

declare -A sc_stale_capacity
declare -A sc_stale_count
declare -A type_stale_count

for pv in $(oc get pv --no-headers | awk '$5 == "Released" {print $1}'); do

  ((total_released++))

  pvc_ns=$(oc get pv "$pv" -o jsonpath='{.spec.claimRef.namespace}' 2>/dev/null)
  pvc_name=$(oc get pv "$pv" -o jsonpath='{.spec.claimRef.name}' 2>/dev/null)
  sc=$(oc get pv "$pv" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
  old_capacity=$(oc get pv "$pv" -o jsonpath='{.spec.capacity.storage}' 2>/dev/null)

  # Detect volume type
  csi_handle=$(oc get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)

  if [ -n "$csi_handle" ]; then
      volume_type="CSI"
      volume_id_old="$csi_handle"
  else
      nfs_server=$(oc get pv "$pv" -o jsonpath='{.spec.nfs.server}' 2>/dev/null)
      nfs_path=$(oc get pv "$pv" -o jsonpath='{.spec.nfs.path}' 2>/dev/null)

      if [ -n "$nfs_server" ]; then
          volume_type="NFS"
          volume_id_old="${nfs_server}:${nfs_path}"
      else
          volume_type="OTHER"
          volume_id_old="UNKNOWN"
      fi
  fi

  if [ -z "$pvc_ns" ] || [ -z "$pvc_name" ]; then

    ((missing_claim++))

    printf "%-30s %-10s %-35s %-12s %-20s %-25s %-25s %-18s %-30s %-35s %-12s\n" \
    "$pv" "$volume_type" "$volume_id_old" "$old_capacity" "$sc" "-" "-" "Missing claimRef" "-" "-" "-"

    echo "$pv,$volume_type,$volume_id_old,$old_capacity,$sc,-,-,Missing claimRef,-,-,-" >> "$csv_file"
    continue
  fi

  if oc get pvc "$pvc_name" -n "$pvc_ns" &>/dev/null; then

      ((reused_count++))

      new_pv=$(oc get pvc "$pvc_name" -n "$pvc_ns" -o jsonpath='{.spec.volumeName}')
      new_capacity=$(oc get pv "$new_pv" -o jsonpath='{.spec.capacity.storage}' 2>/dev/null)

      csi_new=$(oc get pv "$new_pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)

      if [ -n "$csi_new" ]; then
          volume_id_new="$csi_new"
      else
          nfs_server_new=$(oc get pv "$new_pv" -o jsonpath='{.spec.nfs.server}' 2>/dev/null)
          nfs_path_new=$(oc get pv "$new_pv" -o jsonpath='{.spec.nfs.path}' 2>/dev/null)
          volume_id_new="${nfs_server_new}:${nfs_path_new}"
      fi

      printf "%-30s %-10s %-35s %-12s %-20s %-25s %-25s %-18s %-30s %-35s %-12s\n" \
      "$pv" "$volume_type" "$volume_id_old" "$old_capacity" "$sc" "$pvc_ns" "$pvc_name" "PVC_REUSED" "$new_pv" "$volume_id_new" "$new_capacity"

      echo "$pv,$volume_type,$volume_id_old,$old_capacity,$sc,$pvc_ns,$pvc_name,PVC_REUSED,$new_pv,$volume_id_new,$new_capacity" >> "$csv_file"

  else

      ((safe_delete_count++))

      sc_stale_count["$sc"]=$(( ${sc_stale_count["$sc"]:-0} + 1 ))
      type_stale_count["$volume_type"]=$(( ${type_stale_count["$volume_type"]:-0} + 1 ))

      cap_num=$(echo "$old_capacity" | sed 's/Gi//')
      sc_stale_capacity["$sc"]=$(( ${sc_stale_capacity["$sc"]:-0} + cap_num ))

      printf "%-30s %-10s %-35s %-12s %-20s %-25s %-25s %-18s %-30s %-35s %-12s\n" \
      "$pv" "$volume_type" "$volume_id_old" "$old_capacity" "$sc" "$pvc_ns" "$pvc_name" "SAFE_TO_DELETE" "-" "-" "-"

      echo "$pv,$volume_type,$volume_id_old,$old_capacity,$sc,$pvc_ns,$pvc_name,SAFE_TO_DELETE,-,-,-" >> "$csv_file"

  fi

done

echo
echo "=============================="
echo " Released PV Summary"
echo "=============================="

echo "Total Released PVs scanned : $total_released"
echo "PVC Reused                 : $reused_count"
echo "Safe to Delete             : $safe_delete_count"
echo "Missing claimRef           : $missing_claim"

echo
echo "------ Stale Volume Usage by StorageClass ------"

for sc in "${!sc_stale_count[@]}"; do
    echo "StorageClass: $sc | Stale Volumes: ${sc_stale_count[$sc]} | Capacity: ${sc_stale_capacity[$sc]}Gi"
done

echo
echo "------ Stale Volume Usage by Volume Type ------"

for type in "${!type_stale_count[@]}"; do
    echo "Volume Type: $type | Stale Volumes: ${type_stale_count[$type]}"
done

echo
echo "CSV file created: $csv_file"
