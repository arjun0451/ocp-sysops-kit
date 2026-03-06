###etcd compaction time 
for i in $(oc get pods -n openshift-etcd -l app=etcd -o name); do
  echo "== Checking $i =="

  pattern='finished scheduled compaction'

  count=$(oc logs $i -c etcd -n openshift-etcd | grep -E "$pattern" | wc -l)
  echo "Compaction count: $count"

  echo "Compaction times:"
  oc logs $i -c etcd -n openshift-etcd | grep -E "$pattern" | sed -E 's/.*"took":"([^"]+)".*/\1/' | sort -n

  # Handle both seconds (s) and milliseconds (ms)
  avg_max=$(oc logs $i -c etcd -n openshift-etcd | grep -E "$pattern" | \
    sed -E 's/.*"took":"([0-9.]+)(ms|s)".*/\1 \2/' | \
    awk '{ 
      val=$1; 
      if ($2=="s") val*=1000;   # convert seconds to ms
      sum+=val; 
      if(val>max) max=val; 
      count++ 
    } 
    END {if(count>0) printf "avg: %.3f ms, max: %.3f ms\n", sum/count, max; else print "No data"}')
  echo "$avg_max"

  echo
done
