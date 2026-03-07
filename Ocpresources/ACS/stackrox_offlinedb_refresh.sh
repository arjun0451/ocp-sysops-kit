### Stackrox Offline DB update
#!/bin/bash

set -euo pipefail

# === Configuration ===
ROX_CENTRAL_ADDRESS="central-stackrox.apps.ocp.domain.com:443"
#ROX_API_TOKEN="${ROX_API_TOKEN:-}"

ROX_API_TOKEN="token value"

SUPPORT_PKG_URL="https://install.stackrox.io/collector/support-packages/x86_64/2.9.1/support-pkg-2.9.1-latest.zip"
SCANNER_DB_URL="https://install.stackrox.io/scanner/scanner-vuln-updates.zip"

SUPPORT_PKG_FILE="support-pkg-2.9.1-latest.zip"
SCANNER_DB_FILE="scanner-vuln-updates.zip"

# === Usage ===
usage() {
  echo "Usage: $0 [--download-only | --upload] [--use-existing]"
  echo "  --download-only     Only download the files"
  echo "  --upload            Download and upload the scanner DB and support package"
  echo "  --use-existing      Skip download if files already exist"
  exit 1
}

# === Parse arguments ===
MODE=""
USE_EXISTING=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --download-only)
      MODE="download"
      ;;
    --upload)
      MODE="upload"
      ;;
    --use-existing)
      USE_EXISTING=true
      ;;
    *)
      usage
      ;;
  esac
  shift
done

[[ -z "$MODE" ]] && usage

# === Working directory ===
WORKDIR="acs_upload_$(date +%Y%m%d%H%M%S)"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
echo "[INFO] Working directory: $PWD"

# === Download function ===
download_file() {
  local url="$1"
  local output="$2"

  if [[ "$USE_EXISTING" == true && -f "$output" && -s "$output" ]]; then
    echo "[INFO] Skipping download of $output (already exists)"
    return
  fi

  echo "[INFO] Downloading $output..."
  start_time=$(date +%s)
  curl -L --progress-bar -o "$output" "$url"
  end_time=$(date +%s)
  duration=$((end_time - start_time))
  echo "[INFO] Completed $output in $((duration / 60))m $((duration % 60))s"

  [[ -s "$output" ]] || { echo "[ERROR] $output is empty!"; exit 1; }
}

# === Step 1: Download files ===
download_file "$SUPPORT_PKG_URL" "$SUPPORT_PKG_FILE"
download_file "$SCANNER_DB_URL" "$SCANNER_DB_FILE"

# === Step 2: Upload if needed ===
if [[ "$MODE" == "upload" ]]; then
  if [[ -z "$ROX_API_TOKEN" ]]; then
    echo "[ERROR] ROX_API_TOKEN is not set"
    exit 1
  fi

  export ROX_CENTRAL_ADDRESS
  export ROX_API_TOKEN

  echo "[INFO] Uploading scanner DB..."
  roxctl scanner upload-db \
    -e "$ROX_CENTRAL_ADDRESS" \
    --scanner-db-file="$SCANNER_DB_FILE" \
    --insecure-skip-tls-verify

  echo "[INFO] Uploading support package..."
  roxctl collector support-packages upload "$SUPPORT_PKG_FILE" \
    -e "$ROX_CENTRAL_ADDRESS" \
    --insecure-skip-tls-verify

  echo "[SUCCESS] Uploads completed."
else
  echo "[INFO] Download-only mode complete. Files saved to $PWD"
fi
