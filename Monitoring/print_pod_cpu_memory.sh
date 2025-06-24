#!/bin/bash

read -p "Enter the namespace (or type 'all' for all namespaces): " ns

if [[ "$ns" == "all" ]]; then
  NS_FLAG="--all-namespaces"
else
  NS_FLAG="-n $ns"
fi

echo -e "NAMESPACE\tPOD\tCONTAINER\tCPU_REQUEST (m)\tMEM_REQUEST (MiB)\tCPU_LIMIT (m)\tMEM_LIMIT (MiB)"

oc get pods $NS_FLAG -o json | jq -r '
  [
    .items[] |
    .metadata.namespace as $ns |
    .metadata.name as $pod |
    .spec.containers[] |
    {
      ns: $ns,
      pod: $pod,
      container: .name,
      cpu_req: (.resources.requests.cpu // "0"),
      mem_req: (.resources.requests.memory // "0"),
      cpu_lim: (.resources.limits.cpu // "0"),
      mem_lim: (.resources.limits.memory // "0")
    }
  ] |
  map({
    ns,
    pod,
    container,
    cpu_req_m: (
      if .cpu_req == "0" then 0
      elif .cpu_req | test("m$") then (.cpu_req | sub("m$"; "") | tonumber)
      elif .cpu_req | test("^[0-9.]+$") then (.cpu_req | tonumber * 1000)
      else 0
      end
    ),
    mem_req_mib: (
      if .mem_req == "0" then 0
      elif .mem_req | test("Ki$") then (.mem_req | sub("Ki$"; "") | tonumber) / 1024
      elif .mem_req | test("Mi$") then (.mem_req | sub("Mi$"; "") | tonumber)
      elif .mem_req | test("Gi$") then (.mem_req | sub("Gi$"; "") | tonumber * 1024)
      elif .mem_req | test("^[0-9.]+$") then (.mem_req | tonumber / (1024 * 1024))
      else 0
      end
    ),
    cpu_lim_m: (
      if .cpu_lim == "0" then 0
      elif .cpu_lim | test("m$") then (.cpu_lim | sub("m$"; "") | tonumber)
      elif .cpu_lim | test("^[0-9.]+$") then (.cpu_lim | tonumber * 1000)
      else 0
      end
    ),
    mem_lim_mib: (
      if .mem_lim == "0" then 0
      elif .mem_lim | test("Ki$") then (.mem_lim | sub("Ki$"; "") | tonumber) / 1024
      elif .mem_lim | test("Mi$") then (.mem_lim | sub("Mi$"; "") | tonumber)
      elif .mem_lim | test("Gi$") then (.mem_lim | sub("Gi$"; "") | tonumber * 1024)
      elif .mem_lim | test("^[0-9.]+$") then (.mem_lim | tonumber / (1024 * 1024))
      else 0
      end
    )
  }) as $containers |

  ($containers[] |
    "\(.ns)\t\(.pod)\t\(.container)\t\(.cpu_req_m | floor)\t\(.mem_req_mib | floor)\t\(.cpu_lim_m | floor)\t\(.mem_lim_mib | floor)"
  ),

  (
    $containers
    | reduce .[] as $c (
        {cpu_req:0, mem_req:0, cpu_lim:0, mem_lim:0};
        .cpu_req += $c.cpu_req_m |
        .mem_req += $c.mem_req_mib |
        .cpu_lim += $c.cpu_lim_m |
        .mem_lim += $c.mem_lim_mib
      )
    | "TOTAL\t\t\t\(.cpu_req | floor)\t\(.mem_req | floor)\t\(.cpu_lim | floor)\t\(.mem_lim | floor)"
  )
' | column -t -s $'\t'
