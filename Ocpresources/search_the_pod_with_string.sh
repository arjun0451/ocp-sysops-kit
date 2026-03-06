## Search a string and print the pod name which string have that match
#!/bin/bash

NAMESPACE="ms-dcp-3"
SEARCH_STRING="web-react-secrets"

for pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
  if kubectl get pod "$pod" -n "$NAMESPACE" -o yaml | grep -q "$SEARCH_STRING"; then
    echo "$pod"
  fi
done
