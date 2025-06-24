###Skopeo copy of the images
### Navigate to the mirror release path and copy all the images from the page, if input.txt have any leading space script will take care of it 
https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.16.38/release.txt

input.txt
agent-installer-api-server                     quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:ef494956b9d048f2d338c58dd7abef4df51bb1e5e590b667b6d5793bfe38e397
agent-installer-csr-approver                   quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:fef13e06b4f493c14b792d475b2701a2e80530461d7bd1c9b2fbb0514ff2914b
agent-installer-node-agent                     quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:97f1e82c172e9ee45620e231bf466ff716585e4078334cf33a014867c77b15a7
agent-installer-orchestrator                   quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:6f1efe965b9befd05428f72f9ea575243f643ac3bc4f6fcee813473c3f371b41
agent-installer-utils                          quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:b28b3c431aecafaa6e786c6804a1cfd283ffe7e0e33227446b0a7d9aeee5afd5
alibaba-cloud-controller-manager               quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:962814d101f0b19ade2cbe20ca622b9605f5c17e485538c23cfe393abb5f67b7
alibaba-machine-controllers                    quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:121d654505a8c96c6461580e04eb7758ba1f5170ba4c5646daccea50a9e1e283

##Create a repositry in the ECR with version you wanna push 
aws ecr create-repository --repository-name openshift4-16-38 --region ap-southeast-1

## Excute the skopeocopyimages.sh with arguments 
#!/bin/bash

# Usage:
# ./generate-mapping.sh <ECR_REGISTRY> <REPO_NAME> <TAG> <INPUT_FILE> [push]
# Example:
# ./generate-mapping.sh 771954574916.dkr.ecr.ap-southeast-1.amazonaws.com openshift4-16-37 4.16.37-x86_64 input.txt push

set -euo pipefail

# Set registry auth file
export REGISTRY_AUTH_FILE=/root/.ibm-pak/auth.json

ECR_REGISTRY="$1"
REPO_NAME="$2"
TAG="$3"
INPUT_FILE="$4"
PUSH_FLAG="${5:-}"

OUTPUT_FILE="mapping.txt"
LOG_FILE="skopeo-copy.log"

# Clear previous files
> "$OUTPUT_FILE"
> "$LOG_FILE"

# Clean up leading/trailing whitespace in input
sed -i 's/^[ \t]*//' "$INPUT_FILE"
sed -i 's/[ \t]*$//' "$INPUT_FILE"

echo "🔧 Generating mapping file..."

# Build mapping.txt
while read -r line; do
  [[ -z "$line" ]] && continue

  IMAGE_NAME=$(echo "$line" | awk '{print $1}')
  SOURCE_IMAGE=$(echo "$line" | awk '{print $2}')
  DEST_IMAGE="${ECR_REGISTRY}/${REPO_NAME}:${TAG}-${IMAGE_NAME}"

  echo "${SOURCE_IMAGE}=${DEST_IMAGE}" >> "$OUTPUT_FILE"
done < "$INPUT_FILE"

echo "✅ Mapping file created: $OUTPUT_FILE"

# If 'push' flag is present, perform skopeo copy
if [[ "$PUSH_FLAG" == "push" ]]; then
  echo "🚀 Starting skopeo image push..." | tee -a "$LOG_FILE"
  while IFS='=' read -r SRC DST; do
    echo "📦 Copying: $SRC → $DST" | tee -a "$LOG_FILE"
    skopeo copy --all docker://"${SRC}" docker://"${DST}" 2>&1 | tee -a "$LOG_FILE"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      echo "❌ Failed to copy: $SRC" | tee -a "$LOG_FILE"
    else
      echo "✅ Successfully copied: $DST" | tee -a "$LOG_FILE"
    fi
  done < "$OUTPUT_FILE"
fi
