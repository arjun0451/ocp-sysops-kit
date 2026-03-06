## Check the MCP status , ensure MC status is Match , if Mismatch check and Fix

oc get nodes -ojson | jq -r '
  "Node | Current MC | Desired MC | MC State | MC Status",
  (.items | sort_by(.metadata.name) | .[] |
    {
      name: .metadata.name,
      current: .metadata.annotations["machineconfiguration.openshift.io/currentConfig"],
      desired: .metadata.annotations["machineconfiguration.openshift.io/desiredConfig"],
      state: .metadata.annotations["machineconfiguration.openshift.io/state"]
    } |
    "\(.name) | \(.current) | \(.desired) | \(.state) | \((if .current == .desired then "Match" else "Mismatch" end))"
  )
' | column -t -s '|'
