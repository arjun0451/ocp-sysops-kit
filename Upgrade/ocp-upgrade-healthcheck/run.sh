#!/usr/bin/env bash
# =============================================================================
# run.sh — Build and run the OCP Upgrade Health Check Dashboard
#
# Auth is passed via env vars (OC_TOKEN + OC_SERVER) at run time.
# No kubeconfig file or host oc session needed.
#
# Usage:
#   ./run.sh --token sha256~xxxx --server https://api.mycluster:6443
#   ./run.sh --token sha256~xxxx --server https://api.mycluster:6443 --port 9090
#   ./run.sh --token sha256~xxxx --server https://api.mycluster:6443 --rebuild
#   ./run.sh --token sha256~xxxx --server https://api.mycluster:6443 --script ./my-script.sh
#   ./run.sh --token sha256~xxxx --server https://api.mycluster:6443 --no-autorun
#
# Options:
#   --token TOKEN      OC bearer token  (required for auth)
#   --server URL       OpenShift API server URL, e.g. https://api.cluster:6443
#   --port PORT        Host port to expose dashboard (default: 8080)
#   --script FILE      Custom script to mount (overrides embedded default)
#   --artifacts DIR    Host directory for artifact files (default: ./ocp-artifacts)
#   --name NAME        Container name (default: ocp-hc)
#   --image TAG        Image name:tag  (default: ocp-hc:3.0)
#   --platform ARCH    Force build platform: linux/amd64 or linux/arm64
#   --rebuild          Force image rebuild from scratch
#   --no-autorun       Start container but do not auto-run the check
#   --tls-verify       Enable TLS verification (disabled by default)
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
IMAGE="ocp-hc:3.0"
CONTAINER="ocp-hc"
HOST_PORT=8080
REBUILD=false
AUTO_RUN=true
PLATFORM=""
OC_TOKEN=""
OC_SERVER=""
OC_SKIP_TLS="true"
CUSTOM_SCRIPT=""
ARTIFACT_DIR="$(pwd)/ocp-artifacts"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)       OC_TOKEN="$2";     shift 2 ;;
    --server)      OC_SERVER="$2";    shift 2 ;;
    --port)        HOST_PORT="$2";    shift 2 ;;
    --script)      CUSTOM_SCRIPT="$2"; shift 2 ;;
    --artifacts)   ARTIFACT_DIR="$2"; shift 2 ;;
    --name)        CONTAINER="$2";    shift 2 ;;
    --image)       IMAGE="$2";        shift 2 ;;
    --platform)    PLATFORM="$2";     shift 2 ;;
    --rebuild)     REBUILD=true;      shift ;;
    --no-autorun)  AUTO_RUN=false;    shift ;;
    --tls-verify)  OC_SKIP_TLS="false"; shift ;;
    -h|--help)
      sed -n '/^# Usage/,/^# =====/p' "$0" | grep -v '^# =====' | sed 's/^# \{0,2\}//'
      exit 0 ;;
    *) echo "Unknown option: $1  (run with --help for usage)"; exit 1 ;;
  esac
done

DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Validate ──────────────────────────────────────────────────────────────────
if ! command -v podman &>/dev/null; then
  echo ""
  echo "ERROR: podman not found."
  echo ""
  echo "  RHEL / Fedora / CentOS : sudo dnf install -y podman"
  echo "  Ubuntu / Debian        : sudo apt-get install -y podman"
  echo "  macOS (Homebrew)       : brew install podman"
  echo "                           podman machine init && podman machine start"
  echo ""
  exit 1
fi

if [[ -z "$OC_TOKEN" || -z "$OC_SERVER" ]]; then
  echo ""
  echo "ERROR: --token and --server are required."
  echo ""
  echo "  Get your token from an active oc session:"
  echo "    oc whoami -t"
  echo ""
  echo "  Then run:"
  echo "    ./run.sh --token sha256~<token> --server https://api.<cluster>:6443"
  echo ""
  exit 1
fi

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  OCP Upgrade Health Check Dashboard v3"
echo "============================================================"
echo ""
echo "  Image     : $IMAGE"
echo "  Container : $CONTAINER"
echo "  Port      : $HOST_PORT -> 8080"
echo "  Server    : $OC_SERVER"
echo "  Auto-run  : $AUTO_RUN"
echo "  Artifacts : $ARTIFACT_DIR"
echo ""

# ── Stop existing container ───────────────────────────────────────────────────
if podman container exists "$CONTAINER" 2>/dev/null; then
  echo "[setup] Stopping existing container: $CONTAINER"
  podman stop "$CONTAINER" 2>/dev/null || true
  podman rm   "$CONTAINER" 2>/dev/null || true
fi

# ── Build image ───────────────────────────────────────────────────────────────
if $REBUILD || ! podman image exists "$IMAGE" 2>/dev/null; then
  echo "[build] Building $IMAGE ..."
  echo "[build] Base: registry.access.redhat.com/ubi9/nodejs-20"
  echo ""

  BUILD_FLAGS=(-t "$IMAGE" -f "${DIR}/Containerfile" "${DIR}")
  [[ -n "$PLATFORM" ]] && BUILD_FLAGS+=(--platform "$PLATFORM")

  podman build "${BUILD_FLAGS[@]}"
  echo ""
  echo "[build] Image built successfully."
else
  echo "[build] Image $IMAGE already exists. Use --rebuild to force rebuild."
fi

# ── Create artifact directory ─────────────────────────────────────────────────
mkdir -p "$ARTIFACT_DIR"

# ── Build podman run command ──────────────────────────────────────────────────
RUN_FLAGS=(
  --detach
  --name   "$CONTAINER"
  --publish "${HOST_PORT}:8080"
  --restart unless-stopped

  # Auth — token + server passed as env vars (never written to disk in container)
  --env "OC_TOKEN=${OC_TOKEN}"
  --env "OC_SERVER=${OC_SERVER}"
  --env "OC_SKIP_TLS=${OC_SKIP_TLS}"

  # Dashboard config
  --env "AUTO_RUN=${AUTO_RUN}"
  --env "PORT=8080"
  --env "ARTIFACT_BASE=/artifacts"

  # Artifacts: host dir bind-mounted into container
  --volume "${ARTIFACT_DIR}:/artifacts:z"

  # SELinux compatibility for volume mounts on RHEL/Fedora hosts
  --security-opt label=disable
)

# Optional: custom script override
if [[ -n "$CUSTOM_SCRIPT" ]]; then
  CUSTOM_SCRIPT="$(realpath "$CUSTOM_SCRIPT")"
  if [[ ! -f "$CUSTOM_SCRIPT" ]]; then
    echo "[script] WARNING: script not found: $CUSTOM_SCRIPT — using embedded default."
  else
    RUN_FLAGS+=(--volume "${CUSTOM_SCRIPT}:/scripts/ocp-upgrade-healthcheck-v6.sh:ro,z")
    echo "[script] Custom script mounted: $CUSTOM_SCRIPT"
  fi
else
  echo "[script] Using embedded default script."
fi

echo ""
echo "[run] Starting container ..."
podman run "${RUN_FLAGS[@]}" "$IMAGE"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Container started: $CONTAINER"
echo "============================================================"
echo ""
echo "  Dashboard : http://localhost:${HOST_PORT}"
echo "  Logs      : podman logs -f ${CONTAINER}"
echo "  Stop      : podman stop ${CONTAINER}"
echo "  Remove    : podman rm -f ${CONTAINER}"
echo "  Rebuild   : ./run.sh --rebuild --token ... --server ..."
echo ""
echo "  Artifacts will be written to: $ARTIFACT_DIR"
echo ""

# Brief wait then verify container came up
sleep 2
STATUS=$(podman inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo unknown)
if [[ "$STATUS" == "running" ]]; then
  echo "  Container status: running"
else
  echo "  Container status: $STATUS — check logs: podman logs $CONTAINER"
fi
echo ""
