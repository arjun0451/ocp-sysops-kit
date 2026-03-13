# OCP Upgrade Health Check Dashboard — v4.0

A fully self-contained Podman container that runs 25 pre-upgrade health checks
against an OpenShift cluster and streams results to a live web dashboard.

**Bundles inside the image (no host dependencies beyond Podman):**
- `oc` — OpenShift CLI (linux/amd64 rhel9 or linux/arm64)
- `jq` — JSON processor
- `ocp-upgrade-healthcheck-v7.sh` — 25-check health check script
- Node.js 20 Express dashboard (single-page, dark/light mode)

---

## What the 25 checks cover

| # | Check | # | Check |
|---|---|---|---|
| 01 | Cluster Version & upgrade path | 14 | Pending CSRs |
| 02 | Cluster Operators health | 15 | Critical Alerts |
| 03 | OLM / OperatorHub operators | 16 | Workload health (crashloops) |
| 04 | Node status | 17 | PodDisruptionBudget analysis |
| 05 | Node resource pressure | 18 | PVC / PV health |
| 06 | MachineConfigPool + MC match | 19 | Disk usage by node role |
| 07 | Control plane label consistency | 20 | Recent warning events |
| 08 | API server & etcd pods | 21 | Route health |
| 09 | etcd conditions | 22 | EgressIP status |
| 10 | etcd DB size (etcdctl) | 23 | Hardware / platform compatibility |
| 11 | Validating / mutating webhooks | 24 | Cloud Credential Operator mode |
| 12 | Deprecated API usage | 25 | Third-party CSI driver compatibility |
| 13 | TLS certificate expiry | | |

---

## File layout

```
ocp-hc/
├── Containerfile                          # Multi-stage offline build
├── README.md                              # This file
├── entrypoint.sh                          # Auth + server start + auto-run
├── prepare-bins.sh                        # Download oc + jq into bin/ (run once)
├── run.sh                                 # Build + push + run helper
├── app/
│   ├── server.js                          # Express API + live output parser
│   ├── package.json
│   └── public/
│       └── index.html                     # Dashboard UI (dark/light, single file)
└── scripts/
    └── ocp-upgrade-healthcheck-v7.sh      # Embedded health check script
```

---

## Prerequisites

| Tool | Where needed | Minimum version |
|---|---|---|
| `podman` | Mac (build) + Linux (run) | 4.x |
| Internet access | Mac (bin download + quay push) | — |
| `quay.io` account | Mac (push) | — |
| No internet | Linux target | — (image loaded from tar) |

---

## Build on macOS (amd64 image for Linux servers)

### Step 1 — Download binaries

The build is fully offline — binaries are baked into the image from your local
`bin/` directory. Download them once on your Mac before building.

```bash
cd ocp-hc/
chmod +x prepare-bins.sh

# Download linux/amd64 binaries (even though your Mac is arm64)
./prepare-bins.sh --arch amd64
```

This creates `bin/oc` and `bin/jq` as Linux amd64 static binaries.
The script will warn "cross-arch — verify inside container" for the version
check — that is expected and harmless on Apple Silicon.

> **Why `--arch amd64`?** The target container runs on Linux x86_64 servers.
> The binaries inside the image must match the *container* arch, not your Mac.

### Step 2 — Start Podman machine (if not already running)

```bash
# Check if machine is running
podman machine list

# If not running:
podman machine start

# If machine doesn't exist yet:
podman machine init --now --cpus 4 --memory 4096
podman machine start
```

### Step 3 — Build the amd64 image

```bash
podman build \
  --platform linux/amd64 \
  --os linux \
  -t ocp-hc:4.0 \
  -f Containerfile \
  .
```

Verify the built image is amd64:

```bash
podman image inspect ocp-hc:4.0 --format '{{.Architecture}}'
# Expected: amd64
```

If it shows `arm64` instead, your Podman machine lacks QEMU emulation.
Re-init the machine and rebuild:

```bash
podman machine stop
podman machine rm
podman machine init --now --rootful --cpus 4 --memory 4096
podman machine start
# Then repeat Step 3
```

### Step 4 — Push to quay.io

```bash
# Log in to quay.io
podman login quay.io
# Enter your quay.io username and password / robot token when prompted

# Tag with your quay namespace
podman tag ocp-hc:4.0 quay.io/<your-username>/ocp-hc:4.0

# Push
podman push quay.io/<your-username>/ocp-hc:4.0
```

Confirm the push succeeded and the manifest shows linux/amd64:

```bash
podman manifest inspect quay.io/<your-username>/ocp-hc:4.0 2>/dev/null | \
  grep -E 'architecture|os' || \
  podman image inspect quay.io/<your-username>/ocp-hc:4.0 --format '{{.Architecture}}'
```

### Step 5 — Save image as tar (for disconnected Linux host)

If your Linux host cannot reach quay.io (air-gapped), export the image to a
tar file and copy it over instead of pulling.

```bash
# Save
podman save ocp-hc:4.0 -o ocp-hc-4.0-amd64.tar

# Compress (optional but recommended for transfer)
gzip ocp-hc-4.0-amd64.tar

# Verify tar before transfer
tar -tzf ocp-hc-4.0-amd64.tar.gz | head -5

# Copy to Linux bastion / target host
scp ocp-hc-4.0-amd64.tar.gz user@bastion.example.com:/tmp/
```

---

## Deploy on disconnected Linux host

### Option A — Load from tar (fully air-gapped)

```bash
# On the Linux target host
cd /tmp

# Load the image
podman load -i ocp-hc-4.0-amd64.tar.gz

# Verify it loaded and is the right arch
podman images ocp-hc:4.0
podman image inspect ocp-hc:4.0 --format '{{.Os}}/{{.Architecture}}'
# Expected: linux/amd64
```

### Option B — Pull from quay.io (if host has registry access)

```bash
podman pull quay.io/<your-username>/ocp-hc:4.0

# Re-tag to the local name run.sh expects
podman tag quay.io/<your-username>/ocp-hc:4.0 ocp-hc:4.0
```

### Run the dashboard

Copy the `ocp-hc/` folder (or just `run.sh`) to the Linux host, then:

```bash
chmod +x run.sh

# Get a token from your active oc session
oc whoami -t

./run.sh \
  --token sha256~<your-token> \
  --server https://api.<cluster-name>.<domain>:6443
```

The dashboard will be available at **http://localhost:8080**

For remote access over SSH tunnel:

```bash
# From your laptop
ssh -L 8080:localhost:8080 user@bastion.example.com

# Then open in browser
open http://localhost:8080
```

---

## Verify the image works correctly

Run these checks after loading/pulling on the Linux host:

```bash
# 1. Confirm arch is amd64
podman image inspect ocp-hc:4.0 --format '{{.Os}}/{{.Architecture}}'
# → linux/amd64

# 2. Confirm oc and jq work inside the container
podman run --rm ocp-hc:4.0 /bin/bash -c "oc version --client && jq --version"
# → Client Version: 4.x.x
# → jq-1.7.1

# 3. Confirm the health check script is present and executable
podman run --rm ocp-hc:4.0 ls -lh /app/scripts/ocp-upgrade-healthcheck-v7.sh
# → -rwxr-xr-x ... /app/scripts/ocp-upgrade-healthcheck-v7.sh

# 4. Confirm the Node.js server starts (no syntax errors)
podman run --rm \
  -e OC_TOKEN=dummy \
  -e OC_SERVER=https://dummy:6443 \
  -e AUTO_RUN=false \
  -p 8080:8080 \
  ocp-hc:4.0 &
sleep 4
curl -sf http://localhost:8080/api/status | python3 -m json.tool
podman stop ocp-hc 2>/dev/null; podman rm ocp-hc 2>/dev/null
```

---

## All run.sh options

```
--token TOKEN        OC bearer token (required)
--server URL         OpenShift API server URL, e.g. https://api.cluster:6443 (required)
--port PORT          Host port to expose dashboard (default: 8080)
--platform ARCH      Target arch for image build: amd64 or arm64
                     Always set this when building on macOS for a Linux server
--rebuild            Force image rebuild from scratch
--script FILE        Custom health check script (overrides embedded v7)
--artifacts DIR      Host directory for artifact output (default: ./ocp-artifacts)
--name NAME          Container name (default: ocp-hc)
--image TAG          Image name:tag (default: ocp-hc:4.0)
--no-autorun         Start container but do not auto-run the check on startup
--tls-verify         Enable TLS certificate verification (default: skip)
```

Example — custom port, no autorun:

```bash
./run.sh \
  --token sha256~xxxx \
  --server https://api.cluster:6443 \
  --port 9090 \
  --no-autorun
```

---

## Manual podman commands

```bash
# Build for amd64 on macOS
podman build \
  --platform linux/amd64 --os linux \
  -t ocp-hc:4.0 -f Containerfile .

# Run with token auth
podman run -d \
  --name ocp-hc \
  -p 8080:8080 \
  -e OC_TOKEN="sha256~xxxx" \
  -e OC_SERVER="https://api.cluster:6443" \
  -e OC_SKIP_TLS="true" \
  -e AUTO_RUN="true" \
  -e ARTIFACT_BASE="/artifacts" \
  -v ./ocp-artifacts:/artifacts:z \
  --security-opt label=disable \
  --restart unless-stopped \
  ocp-hc:4.0

# Stream logs
podman logs -f ocp-hc

# Shell into container for debugging
podman exec -it ocp-hc bash

# Stop and remove
podman stop ocp-hc && podman rm ocp-hc
```

---

## Custom script override

Mount your own version of the health check script at run time:

```bash
./run.sh \
  --token sha256~xxxx \
  --server https://api.cluster:6443 \
  --script /path/to/ocp-upgrade-healthcheck-v7.sh
```

Or directly with podman:

```bash
podman run -d \
  -v /path/to/ocp-upgrade-healthcheck-v7.sh:/scripts/ocp-upgrade-healthcheck-v7.sh:ro,z \
  ... ocp-hc:4.0
```

---

## Dashboard features

| Feature | Description |
|---|---|
| Dark / Light mode | Toggle with the ☽ button in the header — preference saved |
| Auto-run | Health check starts automatically when container starts |
| Manual run | Click "Run Health Check" to trigger at any time |
| Left sidebar | All 25 checks with live PASS / WARN / FAIL / SKIP / RUN status |
| Terminal | Full script output with ANSI colour rendering |
| Run Metrics | Live failure and warning counters update as script runs |
| Result card | PASS / WARNING / FAILED with exit code mapping |
| Auth card | Shows cluster URL, username, and auth method |
| Progress bar | Tracks script progress across 25 checks |
| Downloads | Full log (.txt) and summary (.json) after run completes |
| Artifact files | All generated report files downloadable from the UI |
| Page reload | Catches up with a completed or in-progress run automatically |

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `OC_TOKEN` | (required) | Bearer token for `oc login` |
| `OC_SERVER` | (required) | OpenShift API server URL |
| `OC_SKIP_TLS` | `true` | Skip TLS verification on token login |
| `PORT` | `8080` | Web server port inside container |
| `SCRIPT_PATH` | `/app/scripts/ocp-upgrade-healthcheck-v7.sh` | Script to execute |
| `ARTIFACT_BASE` | `/artifacts` | Artifact output directory inside container |
| `AUTO_RUN` | `true` | Auto-run health check on container start |

---

## Security notes

- Container runs as UID 1000 (non-root, `node` user)
- Token is passed via env var — never written to the image or disk
- No secrets baked into the image
- `--security-opt label=disable` is set to allow volume mounts on SELinux hosts (RHEL/Fedora)
- For remote access, use an SSH tunnel rather than exposing port 8080 publicly

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Architecture: arm64` after amd64 build | Podman machine lacks QEMU | Re-init machine, see Step 3 |
| `oc version` fails inside container | Wrong arch binary in `bin/` | Re-run `prepare-bins.sh --arch amd64` |
| Dashboard shows "Not Connected" | Bad token or server URL | Check `--token` and `--server` values |
| Run Metrics show `--` after run | Server restarted (state lost) | Re-run health check |
| Container exits immediately | Node.js syntax error | Check `podman logs ocp-hc` |
| Port already in use | Another container on 8080 | Use `--port 9090` |
| `podman save` tar is huge | Uncompressed | Add `gzip` or use `-o file.tar` then `gzip` |
