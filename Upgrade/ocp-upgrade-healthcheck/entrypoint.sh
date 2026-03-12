#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh
# Primary auth: OC_TOKEN + OC_SERVER  (env vars passed at podman run time)
# Fallback    : /kubeconfig  (volume-mounted file)
# =============================================================================
set -euo pipefail

C_RST="\033[0m"; C_BLD="\033[1m"
C_RED="\033[31m"; C_GRN="\033[32m"; C_YLW="\033[33m"; C_CYN="\033[36m"

log()  { printf "${C_CYN}[init]${C_RST} %s\n" "$*"; }
ok()   { printf "${C_GRN}[init]${C_RST} %s\n" "$*"; }
warn() { printf "${C_YLW}[warn]${C_RST} %s\n" "$*"; }
die()  { printf "${C_RED}[FAIL]${C_RST} %s\n" "$*" >&2; exit 1; }

printf "\n${C_BLD}================================================${C_RST}\n"
printf "${C_BLD}  OCP Upgrade Health Check Dashboard v3${C_RST}\n"
printf "${C_BLD}================================================${C_RST}\n\n"

# ── 1. Verify bundled tools ───────────────────────────────────────────────────
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

OC_PATH="$(command -v oc  2>/dev/null)" || die "oc not found — image may need rebuild"
JQ_PATH="$(command -v jq  2>/dev/null)" || die "jq not found — image may need rebuild"
OC_VER="$(oc version --client 2>/dev/null | awk '/Client Version/{print $NF}')"
JQ_VER="$(jq --version 2>/dev/null)"

ok "oc  : $OC_PATH  ($OC_VER)"
ok "jq  : $JQ_PATH  ($JQ_VER)"
echo ""

# ── 2. OpenShift authentication ───────────────────────────────────────────────
AUTH_OK=false
AUTH_METHOD="none"
AUTH_USER=""
AUTH_SERVER=""
AUTH_ERR=""

# Primary: OC_TOKEN + OC_SERVER env vars
if [[ -n "${OC_TOKEN:-}" && -n "${OC_SERVER:-}" ]]; then
  log "Token login -> $OC_SERVER"
  RC=0
  OUT=$(oc login "$OC_SERVER" \
        --token="$OC_TOKEN" \
        --insecure-skip-tls-verify="${OC_SKIP_TLS:-true}" 2>&1) || RC=$?
  if [[ $RC -eq 0 ]]; then
    AUTH_OK=true
    AUTH_METHOD="token"
    AUTH_USER="$(oc whoami 2>/dev/null || echo unknown)"
    AUTH_SERVER="$OC_SERVER"
    ok "Logged in as : $AUTH_USER"
    ok "API server   : $AUTH_SERVER"
  else
    # Sanitize token from error message before storing
    SAFE_OUT="${OUT//$OC_TOKEN/***}"
    AUTH_ERR="Token login failed: $SAFE_OUT"
    warn "$AUTH_ERR"
  fi

# Fallback: kubeconfig volume mount
elif [[ -f "${KUBECONFIG:-/kubeconfig}" ]]; then
  KUBE_FILE="${KUBECONFIG:-/kubeconfig}"
  export KUBECONFIG="$KUBE_FILE"
  log "Kubeconfig: $KUBE_FILE"
  RC=0
  oc whoami &>/dev/null 2>&1 || RC=$?
  if [[ $RC -eq 0 ]]; then
    AUTH_OK=true
    AUTH_METHOD="kubeconfig"
    AUTH_USER="$(oc whoami 2>/dev/null || echo unknown)"
    AUTH_SERVER="$(oc whoami --show-server 2>/dev/null || echo unknown)"
    ok "Logged in as : $AUTH_USER"
    ok "API server   : $AUTH_SERVER"
  else
    AUTH_ERR="Kubeconfig found at $KUBE_FILE but oc whoami failed — token may be expired"
    warn "$AUTH_ERR"
  fi

else
  AUTH_ERR="No auth configured. Pass: -e OC_TOKEN=<token> -e OC_SERVER=https://api.cluster:6443"
  warn "No auth configured."
  warn "  Primary : -e OC_TOKEN=<token> -e OC_SERVER=https://api.cluster:6443"
  warn "  Fallback: -v /path/to/kubeconfig:/kubeconfig:ro"
  warn "Health check will report auth failure until credentials are provided."
fi

echo ""

# ── 3. Script resolution ──────────────────────────────────────────────────────
MOUNTED_SCRIPT="/scripts/ocp-upgrade-healthcheck-v6.sh"
EMBEDDED_SCRIPT="/app/scripts/ocp-upgrade-healthcheck-v6.sh"

if [[ -f "$MOUNTED_SCRIPT" ]]; then
  chmod +x "$MOUNTED_SCRIPT" 2>/dev/null || true
  ACTIVE_SCRIPT="$MOUNTED_SCRIPT"
  SCRIPT_SOURCE="mounted"
  ok "Script [mounted]  : $ACTIVE_SCRIPT"
elif [[ -f "$EMBEDDED_SCRIPT" ]]; then
  ACTIVE_SCRIPT="$EMBEDDED_SCRIPT"
  SCRIPT_SOURCE="embedded"
  ok "Script [embedded] : $ACTIVE_SCRIPT"
else
  die "No health check script found. Mount with -v /path/to/script.sh:/scripts/ocp-upgrade-healthcheck-v6.sh:ro"
fi

export SCRIPT_PATH="$ACTIVE_SCRIPT"
export ARTIFACT_BASE="${ARTIFACT_BASE:-/artifacts}"
# Create artifacts dir — server.js handles permission fallback at run time
mkdir -p "$ARTIFACT_BASE" 2>/dev/null || true

# ── 4. Write auth-status.json (read by dashboard /api/auth) ──────────────────
# Escape double-quotes in error string so JSON stays valid
SAFE_ERR="${AUTH_ERR//\"/\'}"
cat > /tmp/auth-status.json <<JSONEOF
{
  "ok": $AUTH_OK,
  "method": "$AUTH_METHOD",
  "user": "$AUTH_USER",
  "server": "$AUTH_SERVER",
  "error": "$SAFE_ERR",
  "script": "$ACTIVE_SCRIPT",
  "scriptSource": "$SCRIPT_SOURCE",
  "ocVersion": "$OC_VER",
  "jqVersion": "$JQ_VER"
}
JSONEOF

log "Auth status written -> /tmp/auth-status.json"
echo ""

# ── 5. Start dashboard server ─────────────────────────────────────────────────
log "Starting Node.js dashboard on :${PORT:-8080} ..."
log "URL: http://localhost:${PORT:-8080}"
echo ""

# ── 6. Auto-run the health check after server is ready ───────────────────────
if [[ "${AUTO_RUN:-true}" == "true" ]]; then
  (
    i=0; MAX=40
    while [[ $i -lt $MAX ]]; do
      curl -sf "http://localhost:${PORT:-8080}/api/status" &>/dev/null && break
      sleep 0.5; (( i++ )) || true
    done
    log "Auto-run: triggering health check ..."
    curl -sf -X POST "http://localhost:${PORT:-8080}/api/run" &>/dev/null || true
  ) &
fi

# ── 7. Keep container alive by running server in foreground ──────────────────
exec node /app/server.js
