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
#   ./run.sh --token sha256~xxxx --server https://api.mycluster:6443 --platform amd64
#   ./run.sh --token sha256~xxxx --server https://api.mycluster:6443 --script ./my-script.sh
#   ./run.sh --token sha256~xxxx --server https://api.mycluster:6443 --no-autorun
#
# Options:
#   --token TOKEN      OC bearer token  (required)
#   --server URL       OpenShift API server URL, e.g. https://api.cluster:6443 (required)
#   --port PORT        Host port to expose dashboard (default: 8080)
#   --script FILE      Custom script to mount (overrides embedded default)
#   --artifacts DIR    Host directory for artifact files (default: ./ocp-artifacts)
#   --name NAME        Container name (default: ocp-hc)
#   --image TAG        Image name:tag  (default: ocp-hc:4.0)
#   --platform ARCH    Target arch for image build: amd64 or arm64
#                      Always specify this when building on macOS for a Linux server.
#   --rebuild          Force image rebuild
#   --no-autorun       Start container but do not auto-run the check
#   --tls-verify       Enable TLS verification (disabled by default)
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
IMAGE="ocp-hc:4.0"
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
    --token)       OC_TOKEN="$2";      shift 2 ;;
    --server)      OC_SERVER="$2";     shift 2 ;;
    --port)        HOST_PORT="$2";     shift 2 ;;
    --script)      CUSTOM_SCRIPT="$2"; shift 2 ;;
    --artifacts)   ARTIFACT_DIR="$2";  shift 2 ;;
    --name)        CONTAINER="$2";     shift 2 ;;
    --image)       IMAGE="$2";         shift 2 ;;
    --platform)    PLATFORM="$2";      shift 2 ;;
    --rebuild)     REBUILD=true;       shift ;;
    --no-autorun)  AUTO_RUN=false;     shift ;;
    --tls-verify)  OC_SKIP_TLS="false"; shift ;;
    -h|--help)
      sed -n '/^# Usage/,/^# =====/p' "$0" | grep -v '^# =====' | sed 's/^# \{0,2\}//'
      exit 0 ;;
    *) echo "Unknown option: $1  (run with --help for usage)"; exit 1 ;;
  esac
done

DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Detect host OS and arch ───────────────────────────────────────────────────
HOST_OS="$(uname -s)"     # Darwin | Linux
HOST_ARCH="$(uname -m)"  # x86_64 | arm64 | aarch64

# Normalise host arch to amd64/arm64
case "$HOST_ARCH" in
  x86_64)        HOST_ARCH_NORM="amd64" ;;
  aarch64|arm64) HOST_ARCH_NORM="arm64" ;;
  *) HOST_ARCH_NORM="$HOST_ARCH" ;;
esac

# Normalise --platform flag (accept amd64, arm64, linux/amd64, linux/arm64)
if [[ -n "$PLATFORM" ]]; then
  PLATFORM="${PLATFORM#linux/}"    # strip leading "linux/" if provided
  case "$PLATFORM" in
    amd64|arm64) ;;
    x86_64)  PLATFORM="amd64" ;;
    aarch64) PLATFORM="arm64" ;;
    *) echo "ERROR: Unsupported --platform '$PLATFORM'. Use amd64 or arm64."; exit 1 ;;
  esac
fi

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
  echo "  Get your token:  oc whoami -t"
  echo "  Then run:        ./run.sh --token sha256~<token> --server https://api.<cluster>:6443"
  echo ""
  exit 1
fi

# ── Determine effective build platform ───────────────────────────────────────
# If --platform specified, always use it — even on macOS.
# If not specified, default to host arch (native build).
if [[ -n "$PLATFORM" ]]; then
  BUILD_PLATFORM="linux/${PLATFORM}"
  TARGET_ARCH="$PLATFORM"
else
  BUILD_PLATFORM="linux/${HOST_ARCH_NORM}"
  TARGET_ARCH="$HOST_ARCH_NORM"
fi

# ── Cross-arch warning on macOS ───────────────────────────────────────────────
CROSS_BUILD=false
if [[ "$HOST_OS" == "Darwin" && "$TARGET_ARCH" != "$HOST_ARCH_NORM" ]]; then
  CROSS_BUILD=true
  echo ""
  echo "  [build] Cross-arch build detected: host=$HOST_ARCH_NORM  target=$TARGET_ARCH"
  echo "  [build] Ensuring Podman machine supports emulation ..."
  # Podman on macOS uses a VM — check qemu binfmt support
  if ! podman machine inspect 2>/dev/null | grep -q "CPUs\|Machine"; then
    echo ""
    echo "  WARNING: Podman machine may not be running."
    echo "  Start it with:  podman machine start"
    echo ""
  fi
fi

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  OCP Upgrade Health Check Dashboard v4.0"
echo "============================================================"
echo ""
echo "  Image      : $IMAGE"
echo "  Container  : $CONTAINER"
echo "  Port       : $HOST_PORT -> 8080"
echo "  Server     : $OC_SERVER"
echo "  Auto-run   : $AUTO_RUN"
echo "  Artifacts  : $ARTIFACT_DIR"
echo "  Platform   : $BUILD_PLATFORM  (host: ${HOST_OS}/${HOST_ARCH_NORM})"
echo ""

# ── Stop existing container ───────────────────────────────────────────────────
if podman container exists "$CONTAINER" 2>/dev/null; then
  echo "[setup] Stopping existing container: $CONTAINER"
  podman stop "$CONTAINER" 2>/dev/null || true
  podman rm   "$CONTAINER" 2>/dev/null || true
fi

# ── Build image ───────────────────────────────────────────────────────────────
if $REBUILD || ! podman image exists "$IMAGE" 2>/dev/null; then
  echo "[build] Building $IMAGE  platform=$BUILD_PLATFORM ..."
  echo ""

  BUILD_FLAGS=(
    -t "$IMAGE"
    -f "${DIR}/Containerfile"
    --platform "$BUILD_PLATFORM"
  )

  # On macOS, add --os linux to ensure the image manifest is correctly labelled
  # as a Linux image regardless of the Podman machine's default OS
  if [[ "$HOST_OS" == "Darwin" ]]; then
    BUILD_FLAGS+=(--os linux)
  fi

  # On macOS cross-arch (e.g. M2 building amd64): Podman uses QEMU emulation
  # via the VM — no extra flags needed beyond --platform. However if the
  # Podman machine was initialised without rosetta/qemu support the build
  # will fail at RUN steps; the user must re-init with:
  #   podman machine init --now --rootful --cpus 4 --memory 4096
  if $CROSS_BUILD; then
    echo "  [build] Cross-arch: using QEMU emulation inside Podman VM"
    echo "  [build] This may be slower than a native build."
    echo ""
  fi

  BUILD_FLAGS+=("${DIR}")

  podman build "${BUILD_FLAGS[@]}"

  echo ""
  echo "[build] Image built successfully."

  # Verify the image arch matches what we asked for
  ACTUAL_ARCH=$(podman image inspect "$IMAGE" --format '{{.Architecture}}' 2>/dev/null || echo "unknown")
  echo "[build] Image architecture: $ACTUAL_ARCH"
  if [[ "$ACTUAL_ARCH" != "$TARGET_ARCH" && "$ACTUAL_ARCH" != "unknown" ]]; then
    echo ""
    echo "  WARNING: Built image arch ($ACTUAL_ARCH) != requested ($TARGET_ARCH)."
    echo "  This can happen when Podman falls back to native arch."
    echo "  To fix: ensure qemu-user-static is installed in the Podman VM, or"
    echo "  build on a native $TARGET_ARCH machine."
    echo ""
  fi
else
  ACTUAL_ARCH=$(podman image inspect "$IMAGE" --format '{{.Architecture}}' 2>/dev/null || echo "unknown")
  echo "[build] Image $IMAGE already exists (arch=$ACTUAL_ARCH). Use --rebuild to force rebuild."
fi

# ── Create artifact directory ─────────────────────────────────────────────────
mkdir -p "$ARTIFACT_DIR"

# ── Build podman run command ──────────────────────────────────────────────────
RUN_FLAGS=(
  --detach
  --name   "$CONTAINER"
  --publish "${HOST_PORT}:8080"
  --restart unless-stopped

  # Auth env vars — never written to disk inside container
  --env "OC_TOKEN=${OC_TOKEN}"
  --env "OC_SERVER=${OC_SERVER}"
  --env "OC_SKIP_TLS=${OC_SKIP_TLS}"

  # Dashboard config
  --env "AUTO_RUN=${AUTO_RUN}"
  --env "PORT=8080"
  --env "ARTIFACT_BASE=/artifacts"

  # Artifacts volume
  --volume "${ARTIFACT_DIR}:/artifacts:z"

  # SELinux compatibility
  --security-opt label=disable
)

# Optional: custom script override
SCRIPT_MOUNT="/scripts/ocp-upgrade-healthcheck-v7.sh"
if [[ -n "$CUSTOM_SCRIPT" ]]; then
  CUSTOM_SCRIPT="$(realpath "$CUSTOM_SCRIPT")"
  if [[ ! -f "$CUSTOM_SCRIPT" ]]; then
    echo "[script] WARNING: script not found: $CUSTOM_SCRIPT — using embedded default."
  else
    RUN_FLAGS+=(--volume "${CUSTOM_SCRIPT}:${SCRIPT_MOUNT}:ro,z")
    echo "[script] Custom script mounted: $CUSTOM_SCRIPT"
  fi
else
  echo "[script] Using embedded default script (v7)."
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
echo "  Dashboard  : http://localhost:${HOST_PORT}"
echo "  Logs       : podman logs -f ${CONTAINER}"
echo "  Stop       : podman stop ${CONTAINER}"
echo "  Remove     : podman rm -f ${CONTAINER}"
echo "  Rebuild    : ./run.sh --rebuild --token ... --server ..."
echo ""
echo "  Artifacts will be written to: $ARTIFACT_DIR"
echo ""

# Brief wait then verify
sleep 2
STATUS=$(podman inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo unknown)
if [[ "$STATUS" == "running" ]]; then
  echo "  Container status: running ✓"
else
  echo "  Container status: $STATUS — check logs: podman logs $CONTAINER"
fi
echo ""
