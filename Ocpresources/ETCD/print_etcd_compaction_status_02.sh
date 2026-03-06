for i in $(oc get pods -n openshift-etcd -l app=etcd -o name); do
  echo "== Checking $i =="

  pattern='finished scheduled compaction'

  # Count compactions
  count=$(oc logs $i -c etcd -n openshift-etcd | grep -E "$pattern" | wc -l)
  echo "Compaction count: $count"

  # Extract and display compaction details
  oc logs $i -c etcd -n openshift-etcd | grep -E "$pattern" | \
  sed -E 's/.*"ts":"([^"]+)".*"took":"([^"]+)".*"current-db-size-bytes":([0-9]+).*"current-db-size-in-use-bytes":([0-9]+).*/\1,\2,\3,\4/' | \
  awk -F',' '{
    ts=$1;
    took=$2;
    size=$3;
    used=$4;
    pct=(size-used)/size*100;
    printf "Timestamp: %s | Took: %s | DB Size: %d bytes | In-use: %d bytes | Fragmentation: %.2f%%\n", ts, took, size, used, pct
  }' | sort

  # Compute average/max duration (convert seconds→ms if needed)
  avg_max=$(oc logs $i -c etcd -n openshift-etcd | grep -E "$pattern" | \
    sed -E 's/.*"took":"([0-9.]+)(ms|s)".*/\1 \2/' | \
    awk '{
      val=$1;
      if ($2=="s") val*=1000;   # convert seconds to ms
      sum+=val;
      if(val>max) max=val;
      count++
    }
    END {
      if(count>0)
        printf "Average Duration: %.3f ms | Max Duration: %.3f ms\n", sum/count, max;
      else
        print "No compaction data found"
    }')
  
  echo "$avg_max"
  echo
done
