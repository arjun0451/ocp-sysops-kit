#!/usr/bin/env bash
# =============================================================================
# prepare-bins.sh — Download oc and jq binaries into ./bin/
#
# Run ONCE on any internet-connected machine, then copy the whole ocp-hc/
# folder (including bin/) to your air-gapped host and build there.
#
# Usage:
#   ./prepare-bins.sh                         # auto-detect arch
#   ./prepare-bins.sh --arch amd64            # force amd64 (Linux target)
#   ./prepare-bins.sh --arch arm64            # force arm64 (ARM Linux / Mac M-series)
#
# Notes:
#   - oc amd64 uses the -rhel9 variant from mirror.openshift.com
#   - jq is downloaded for Linux (the target container OS), not the host OS
#   - If running this on macOS to prepare binaries for an amd64 Linux container,
#     pass --arch amd64 explicitly
# =============================================================================
set -euo pipefail

ARCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    *) echo "Unknown option: $1  (use --arch amd64|arm64)"; exit 1 ;;
  esac
done

# Auto-detect host arch if not specified
if [[ -z "$ARCH" ]]; then
  case "$(uname -m)" in
    x86_64)        ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "ERROR: Unknown arch $(uname -m). Use --arch amd64 or --arch arm64"; exit 1 ;;
  esac
fi

if [[ "$ARCH" != "amd64" && "$ARCH" != "arm64" ]]; then
  echo "ERROR: Unsupported arch '$ARCH'. Must be amd64 or arm64."
  exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$DIR/bin"
mkdir -p "$BIN_DIR"

echo ""
echo "============================================================"
echo "  prepare-bins.sh — downloading binaries for: $ARCH"
echo "  Target: $BIN_DIR/"
echo "============================================================"
echo ""

# ── oc (OpenShift CLI) ────────────────────────────────────────────────────────
# amd64: openshift-client-linux-amd64-rhel9.tar.gz  (rhel9 suffix required)
# arm64: openshift-client-linux-arm64.tar.gz
echo "[1/2] Downloading oc (OpenShift CLI) for linux/$ARCH ..."

OC_BASE="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable"
if [[ "$ARCH" == "amd64" ]]; then
  OC_URL="${OC_BASE}/openshift-client-linux-amd64-rhel9.tar.gz"
else
  OC_URL="${OC_BASE}/openshift-client-linux-${ARCH}.tar.gz"
fi

echo "    URL: $OC_URL"
curl -fsSL --progress-bar "$OC_URL" -o /tmp/oc-download.tar.gz
tar -xzf /tmp/oc-download.tar.gz -C "$BIN_DIR" oc
rm -f /tmp/oc-download.tar.gz
chmod +x "$BIN_DIR/oc"

# Verify — may fail on macOS (cross-arch binary) so don't abort
OC_VER=$("$BIN_DIR/oc" version --client 2>/dev/null | awk '/Client Version/{print $NF}') || OC_VER="(cross-arch — verify inside container)"
echo "    oc: $OC_VER"

# ── jq ────────────────────────────────────────────────────────────────────────
# Always download Linux jq (container target), not macOS binary
echo ""
echo "[2/2] Downloading jq for linux/$ARCH ..."
JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${ARCH}"
echo "    URL: $JQ_URL"
curl -fsSL --progress-bar "$JQ_URL" -o "$BIN_DIR/jq"
chmod +x "$BIN_DIR/jq"

# Verify — may fail on macOS (cross-arch)
JQ_VER=$("$BIN_DIR/jq" --version 2>/dev/null) || JQ_VER="(cross-arch — verify inside container)"
echo "    jq: $JQ_VER"

echo ""
echo "============================================================"
echo "  Done. bin/ contents:"
ls -lh "$BIN_DIR/"
echo ""
echo "  Build the image (no internet needed at build time):"
echo "    cd $(dirname "$DIR")"
echo "    ./run.sh --token sha256~<token> --server https://api.<cluster>:6443"
echo ""
echo "  Or build manually:"
echo "    podman build -t ocp-hc:4.0 -f Containerfile ."
if [[ "$(uname -s)" == "Darwin" && "$ARCH" == "amd64" ]]; then
  echo ""
  echo "  NOTE (macOS → amd64): You prepared amd64 binaries on Apple Silicon."
  echo "  Build with: ./run.sh --platform amd64 --token ... --server ..."
  echo "  This forces --platform linux/amd64 in the podman build."
fi
echo "============================================================"
echo ""
