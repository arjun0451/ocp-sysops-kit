###### defrag 

#!/bin/bash
NAMESPACE="openshift-etcd-operator"
ETCD_OPERATOR_POD="etcd-operator-7884b86d9f-wnb7x"

echo "Collecting defragmentation events from pod: $ETCD_OPERATOR_POD"
echo "------------------------------------------------------------------------------------"
echo "Timestamp,Member,Fragmentation %,dbSize (MB),dbInUse (MB),Duration (ms),Result"
echo "------------------------------------------------------------------------------------"

oc logs -n "$NAMESPACE" "$ETCD_OPERATOR_POD" --since=168h | awk -v year="$(date +%Y)" '
  # Match fragmentation log
  /backend store fragmented:/ {
    ts=$1 " " $2               # e.g., I1029 02:13:41.868211
    match($0, /member \"([^\"]+)\"/, a); member=a[1]
    match($0, /fragmented: ([0-9.]+) %/, b); frag=b[1]
    match($0, /dbSize: ([0-9]+)/, c); dbs=c[1]
    match($0, /dbInUse: ([0-9]+)/, d); dbi=d[1]
    frag_ts[member]=ts
    frag_pct[member]=frag
    db_size[member]=dbs/1048576
    db_inuse[member]=dbi/1048576
  }

  # Match defrag attempt
  /DefragControllerDefragmentAttempt/ {
    ts=$1 " " $2
    match($0, /member: ([^,]+)/, a); member=a[1]
    attempt_ts[member]=ts
  }

  # Match defrag success
  /DefragControllerDefragmentSuccess/ {
    ts=$1 " " $2
    match($0, /defragmented: ([^,]+)/, a); member=a[1]
    start=attempt_ts[member]
    if (start != "") {
      # Convert etcd-style timestamp (I1029 02:13:43.705913) to full date for diff calc
      gsub(/^I/, "", start); gsub(/^I/, "", ts)
      cmd1="date -d \"" year substr(start,1,2) substr(start,3,2) " " substr(start,6) "\" +%s.%6N"
      cmd1 | getline t1; close(cmd1)
      cmd2="date -d \"" year substr(ts,1,2) substr(ts,3,2) " " substr(ts,6) "\" +%s.%6N"
      cmd2 | getline t2; close(cmd2)
      dur=(t2-t1)*1000
    } else {
      dur="N/A"
    }

    printf "%s,%s,%s,%.2f,%.2f,%s,Success\n",
      ts, member, frag_pct[member], db_size[member], db_inuse[member], dur
  }
'
