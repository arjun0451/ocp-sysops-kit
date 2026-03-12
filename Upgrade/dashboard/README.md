# OCP Upgrade Health Check — Web Dashboard v2

A Red Hat UBI9 Node.js container that hosts the dashboard web UI.
The health check shell script runs on your host terminal as normal.
The container only runs the Node.js web server.

---

## How it works

```
HOST TERMINAL                       CONTAINER (Podman)
─────────────────                   ──────────────────────────────
./ocp-upgrade-healthcheck-v6.sh     Node.js + Express web server
  -> writes output to screen          -> reads script via bind mount
  -> writes artifacts to /tmp/        -> serves dashboard on :8080
     ocp-artifacts/                   -> streams output to browser
```

The script and the dashboard are independent.
You do not need Node.js installed on the host.

---

## Quick Start

```bash
# 1. Build and start the dashboard container
chmod +x run.sh
./run.sh

# 2. Open the dashboard in your browser
open http://localhost:8080

# 3. Run the health check on the HOST terminal (separately)
./ocp-upgrade-healthcheck-v6.sh

# 4. Watch results stream into the dashboard
```

---

## File layout

```
ocp-dashboard/
  Containerfile                        # Red Hat UBI9 + Node.js 20
  server.js                            # Express web server
  package.json
  public/
    index.html                         # Dashboard UI (single file)
  run.sh                               # Build + run helper
  ocp-upgrade-healthcheck-v6.sh        # Health check script (runs on host)
```

---

## Podman commands (manual)

### Build the image

```bash
podman build -t ocp-upgrade-dashboard:2.0 -f Containerfile .
```

### Run the container

```bash
podman run -d \
  --name ocp-dashboard \
  --publish 8080:8080 \
  --volume $(pwd):/scripts:ro,z \
  --volume /tmp/ocp-artifacts:/artifacts:z \
  --env SCRIPT_PATH=/scripts/ocp-upgrade-healthcheck-v6.sh \
  --env ARTIFACT_BASE=/artifacts \
  --restart unless-stopped \
  ocp-upgrade-dashboard:2.0
```

### Useful commands

```bash
# View logs
podman logs -f ocp-dashboard

# Stop
podman stop ocp-dashboard

# Remove
podman rm -f ocp-dashboard

# Check health
podman inspect ocp-dashboard --format '{{.State.Health.Status}}'

# Rebuild after code changes
./run.sh --rebuild
```

---

## Options for run.sh

```bash
./run.sh --port 9090                          # different host port
./run.sh --script /opt/ocp/healthcheck.sh     # different script path
./run.sh --artifacts /var/ocp-artifacts       # different artifact dir
./run.sh --rebuild                            # force image rebuild
./run.sh --name my-dashboard                  # custom container name
```

---

## Run on an OpenShift/Kubernetes worker node (no internet)

If the host has no access to registry.access.redhat.com:

```bash
# On a machine with internet access — save the image
podman pull registry.access.redhat.com/ubi9/nodejs-20
podman build -t ocp-upgrade-dashboard:2.0 -f Containerfile .
podman save ocp-upgrade-dashboard:2.0 -o ocp-dashboard.tar

# Copy to the target host
scp ocp-dashboard.tar user@target-host:/tmp/

# On the target host — load and run
podman load -i /tmp/ocp-dashboard.tar
podman run -d \
  --name ocp-dashboard \
  --publish 8080:8080 \
  --volume /path/to/scripts:/scripts:ro,z \
  --volume /tmp/ocp-artifacts:/artifacts:z \
  --env SCRIPT_PATH=/scripts/ocp-upgrade-healthcheck-v6.sh \
  --env ARTIFACT_BASE=/artifacts \
  ocp-upgrade-dashboard:2.0
```

---

## Environment variables

| Variable        | Default                                    | Description                  |
|-----------------|--------------------------------------------|------------------------------|
| PORT            | 8080                                       | Port the server listens on   |
| SCRIPT_PATH     | /scripts/ocp-upgrade-healthcheck-v6.sh     | Script path inside container |
| ARTIFACT_BASE   | /artifacts                                 | Artifact directory           |

---

## Security note

The dashboard has no authentication. Run it on a private network or bastion host.
Access from your laptop via SSH tunnel:

```bash
ssh -L 8080:localhost:8080 user@bastion-host
# Then open http://localhost:8080
```
