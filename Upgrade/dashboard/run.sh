#!/usr/bin/env bash
# =============================================================================
# run.sh — Build the OCP dashboard image and start the container
#
# Usage:
#   ./run.sh                          # uses defaults below
#   ./run.sh --port 9090              # custom port
#   ./run.sh --script /path/to/v6.sh  # custom script location
#   ./run.sh --rebuild                # force image rebuild
#
# What this does:
#   1. Builds the Podman image from the Containerfile (once, cached after that)
#   2. Mounts your local script directory and /tmp into the container
#   3. Starts the Node.js web server on the specified port
#
# The shell script still runs on your HOST terminal as normal:
#   ./ocp-upgrade-healthcheck-v6.sh
# The dashboard container watches the output and serves the UI.
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
IMAGE_NAME="ocp-upgrade-dashboard"
IMAGE_TAG="2.0"
CONTAINER_NAME="ocp-dashboard"
HOST_PORT=8080
REBUILD=false

# Script defaults — absolute path to your health check script on the HOST
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_FILE="${SCRIPT_DIR}/ocp-upgrade-healthcheck-v6.sh"

# Artifact output dir on the HOST (container writes here too)
ARTIFACT_DIR="/Users/nagarjunareddy/workingdir/upgradescripts/upgrade2/artifacts"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      HOST_PORT="$2";    shift 2 ;;
    --script)    SCRIPT_FILE="$2";  shift 2 ;;
    --artifacts) ARTIFACT_DIR="$2"; shift 2 ;;
    --rebuild)   REBUILD=true;      shift ;;
    --name)      CONTAINER_NAME="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SCRIPT_FILE="$(realpath "$SCRIPT_FILE" 2>/dev/null || echo "$SCRIPT_FILE")"
SCRIPT_DIR_MOUNT="$(dirname "$SCRIPT_FILE")"

# ── Checks ────────────────────────────────────────────────────────────────────
if ! command -v podman &>/dev/null; then
  echo "ERROR: podman not found. Install it with:"
  echo "  sudo dnf install -y podman     # RHEL/Fedora/CentOS"
  echo "  brew install podman            # macOS"
  exit 1
fi

if [[ ! -f "$SCRIPT_FILE" ]]; then
  echo "WARNING: Script not found at: $SCRIPT_FILE"
  echo "         The dashboard will still start but the Run button will show an error."
  echo "         Set the correct path with: ./run.sh --script /path/to/ocp-upgrade-healthcheck-v6.sh"
fi

mkdir -p "$ARTIFACT_DIR"
echo "Artifact directory: $ARTIFACT_DIR"

# ── Stop existing container ───────────────────────────────────────────────────
if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
  echo "Stopping existing container: $CONTAINER_NAME"
  podman stop "$CONTAINER_NAME" 2>/dev/null || true
  podman rm   "$CONTAINER_NAME" 2>/dev/null || true
fi

# ── Build image ───────────────────────────────────────────────────────────────
CONTAINERFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

if $REBUILD || ! podman image exists "$FULL_IMAGE" 2>/dev/null; then
  echo ""
  echo "Building image: $FULL_IMAGE"
  echo "  Base: registry.access.redhat.com/ubi9/nodejs-20"
  echo ""
  podman build \
    -t "$FULL_IMAGE" \
    -f "${CONTAINERFILE_DIR}/Containerfile" \
    --platform linux/amd64 \
    "${CONTAINERFILE_DIR}"
  echo ""
  echo "Build complete."
fi

# ── Run container ──────────────────────────────────────────────────────────────
echo ""
echo "Starting container: $CONTAINER_NAME"
echo "  Image    : $FULL_IMAGE"
echo "  Port     : $HOST_PORT -> 8080"
echo "  Script   : $SCRIPT_FILE (mounted read-only)"
echo "  Artifacts: $ARTIFACT_DIR (mounted read-write)"
echo ""

podman run \
  --detach \
  --name "$CONTAINER_NAME" \
  --publish "${HOST_PORT}:8080" \
  \
  --volume "${SCRIPT_DIR_MOUNT}:/scripts:ro,z" \
  --volume "${ARTIFACT_DIR}:/artifacts:z" \
  \
  --env "SCRIPT_PATH=/scripts/$(basename "$SCRIPT_FILE")" \
  --env "ARTIFACT_BASE=/artifacts" \
  --env "PORT=8080" \
  \
  --restart unless-stopped \
  --security-opt label=disable \
  \
  "$FULL_IMAGE"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "Dashboard is running."
echo ""
echo "  Open   : http://localhost:${HOST_PORT}"
echo "  Logs   : podman logs -f ${CONTAINER_NAME}"
echo "  Stop   : podman stop ${CONTAINER_NAME}"
echo "  Remove : podman rm -f ${CONTAINER_NAME}"
echo ""
echo "To run the health check (on the host terminal, not inside the container):"
echo "  ./ocp-upgrade-healthcheck-v6.sh"
echo ""
echo "Artifacts written to: $ARTIFACT_DIR"
echo "They are also available for download from the dashboard."
echo ""
