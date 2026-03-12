# Run Guide

## Get your OC token

From any machine already logged into the cluster:

```bash
oc whoami -t
# sha256~xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

---

## Run locally

```bash
./run.sh --token sha256~<token> --server https://api.<cluster>:6443
```

Open **http://localhost:8080**

The health check runs automatically on container start. Click **Run Health Check** in the UI to re-run at any time.

### Options

```
--token TOKEN      OC bearer token (required)
--server URL       OpenShift API server URL (required)
--port PORT        Host port for dashboard (default: 8080)
--script FILE      Override embedded script with a local file
--artifacts DIR    Host directory for output files (default: ./ocp-artifacts)
--no-autorun       Start dashboard but don't auto-run
--rebuild          Force image rebuild
--name NAME        Container name (default: ocp-hc)
```

---

## Run on a remote server using a registry image

### Pull and run

```bash
podman pull quay.io/<org>/ocp-upgrade-healthcheck:latest

podman run -d \
  --name ocp-hc \
  --publish 8080:8080 \
  --restart unless-stopped \
  --security-opt label=disable \
  -e OC_TOKEN="sha256~<token>" \
  -e OC_SERVER="https://api.<cluster>:6443" \
  -e AUTO_RUN=true \
  -v /tmp/ocp-artifacts:/artifacts:z \
  quay.io/<org>/ocp-upgrade-healthcheck:latest
```

Access from your laptop via SSH tunnel:

```bash
ssh -L 8080:localhost:8080 user@remote-server
# Open http://localhost:8080
```

---

## Run in a disconnected environment

```bash
# Load the image (already transferred via podman save/load)
podman load -i /tmp/ocp-upgrade-healthcheck.tar

podman run -d \
  --name ocp-hc \
  --publish 8080:8080 \
  --restart unless-stopped \
  --security-opt label=disable \
  -e OC_TOKEN="sha256~<token>" \
  -e OC_SERVER="https://api.<cluster>:6443" \
  -e AUTO_RUN=true \
  -v /tmp/ocp-artifacts:/artifacts:z \
  ocp-upgrade-healthcheck:latest
```

### Override the embedded script (optional)

```bash
podman run -d \
  --name ocp-hc \
  --publish 8080:8080 \
  --security-opt label=disable \
  -e OC_TOKEN="sha256~<token>" \
  -e OC_SERVER="https://api.<cluster>:6443" \
  -v /path/to/ocp-upgrade-healthcheck-v6.sh:/scripts/ocp-upgrade-healthcheck-v6.sh:ro \
  -v /tmp/ocp-artifacts:/artifacts:z \
  ocp-upgrade-healthcheck:latest
```

---

## Useful commands

```bash
# Live logs
podman logs -f ocp-hc

# Stop / remove
podman stop ocp-hc
podman rm -f ocp-hc

# Shell into container
podman exec -it ocp-hc bash

# Verify bundled tools
podman exec ocp-hc oc version --client
podman exec ocp-hc jq --version
```
