## Get the node capacity in a formatted way
oc get nodes -o json | jq -r '
  .items[] 
  | [
      .metadata.name,

      # CPU capacity (numeric cores)
      (.status.capacity.cpu | tonumber),

      # Memory capacity: Ki → GiB
      (.status.capacity.memory | sub("Ki$"; "") | tonumber / 1024 / 1024),

      # CPU allocatable (m → cores)
      (.status.allocatable.cpu | sub("m$"; "") | tonumber / 1000),

      # Memory allocatable: Ki → GiB
      (.status.allocatable.memory | sub("Ki$"; "") | tonumber / 1024 / 1024)
    ]
  | @tsv
' | column -t
