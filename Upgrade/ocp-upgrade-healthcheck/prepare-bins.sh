#!/usr/bin/env bash
# =============================================================================
# prepare-bins.sh — Download oc and jq binaries into ./bin/ (run ONCE)
#
# Run this on any machine with internet access, then copy the whole
# ocp-hc/ folder (including bin/) to your air-gapped host and build there.
#
# Usage:
#   ./prepare-bins.sh              # auto-detect arch
#   ./prepare-bins.sh --arch amd64
#   ./prepare-bins.sh --arch arm64
# =============================================================================
set -euo pipefail

ARCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Auto-detect if not specified
if [[ -z "$ARCH" ]]; then
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "ERROR: Unknown arch $(uname -m). Use --arch amd64 or --arch arm64"; exit 1 ;;
  esac
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$DIR/bin"
mkdir -p "$BIN_DIR"

echo ""
echo "Downloading binaries for arch: $ARCH -> $BIN_DIR/"
echo ""

# ── oc ────────────────────────────────────────────────────────────────────────
echo "[1/2] Downloading oc (OpenShift CLI) ..."
OC_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux-${ARCH}.tar.gz"
curl -fsSL --progress-bar "$OC_URL" -o /tmp/oc-download.tar.gz
tar -xzf /tmp/oc-download.tar.gz -C "$BIN_DIR" oc
rm -f /tmp/oc-download.tar.gz
chmod +x "$BIN_DIR/oc"
echo "    oc version: $("$BIN_DIR/oc" version --client 2>/dev/null | awk '/Client Version/{print $NF}')"

# ── jq ────────────────────────────────────────────────────────────────────────
echo "[2/2] Downloading jq ..."
JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${ARCH}"
curl -fsSL --progress-bar "$JQ_URL" -o "$BIN_DIR/jq"
chmod +x "$BIN_DIR/jq"
echo "    jq version: $("$BIN_DIR/jq" --version)"

echo ""
echo "Done. bin/ folder contents:"
ls -lh "$BIN_DIR/"
echo ""
echo "Now build the image (internet not required):"
echo "  podman build -t ocp-hc:3.0 -f Containerfile ."
echo ""
