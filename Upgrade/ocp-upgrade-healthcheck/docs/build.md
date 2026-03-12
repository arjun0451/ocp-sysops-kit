# Build Guide

## Prerequisites

- `podman` installed
- `oc` and `jq` binaries placed in `bin/` (see Step 1)

---

## Step 1 — Prepare binaries

Run once on any internet-connected machine:

```bash
./prepare-bins.sh              # auto-detects arch

# Or specify explicitly:
./prepare-bins.sh --arch amd64   # Linux x86_64
./prepare-bins.sh --arch arm64   # Apple Silicon Mac
```

This places `bin/oc` and `bin/jq` in the build context. These are copied into the image — no downloads happen during the build.

---

## Step 2 — Build

```bash
podman build -t ocp-upgrade-healthcheck:latest -f Containerfile .

# With a version tag:
podman build -t ocp-upgrade-healthcheck:1.0.0 -f Containerfile .

# Force specific platform:
podman build --platform linux/amd64 -t ocp-upgrade-healthcheck:latest -f Containerfile .
```

---

## Disconnected / Air-gapped Build

### On the internet-connected machine

```bash
# 1. Prepare binaries
./prepare-bins.sh --arch amd64

# 2. Pull base images
podman pull alpine:3.19
podman pull node:20-slim

# 3. Build
podman build -t ocp-upgrade-healthcheck:latest -f Containerfile .

# 4. Save to tar
podman save ocp-upgrade-healthcheck:latest -o ocp-upgrade-healthcheck.tar

# 5. Transfer to disconnected host
scp ocp-upgrade-healthcheck.tar user@host:/tmp/
```

### On the disconnected host

```bash
podman load -i /tmp/ocp-upgrade-healthcheck.tar
```

---

## Push to Registry

### Quay.io

```bash
podman login quay.io

podman tag ocp-upgrade-healthcheck:latest quay.io/<org>/ocp-upgrade-healthcheck:latest
podman push quay.io/<org>/ocp-upgrade-healthcheck:latest
```

### Docker Hub

```bash
podman login docker.io

podman tag ocp-upgrade-healthcheck:latest docker.io/<username>/ocp-upgrade-healthcheck:latest
podman push docker.io/<username>/ocp-upgrade-healthcheck:latest
```

### Internal registry

```bash
podman tag ocp-upgrade-healthcheck:latest registry.example.com/ocp-tools/ocp-upgrade-healthcheck:latest
podman push registry.example.com/ocp-tools/ocp-upgrade-healthcheck:latest
```

---

## GitHub Actions (CI auto-build)

The workflow in `.github/workflows/build-push.yml` triggers on version tags and pushes to Quay.io.

Add these secrets to your GitHub repository:

| Secret | Value |
|---|---|
| `QUAY_USERNAME` | Quay.io robot account username |
| `QUAY_PASSWORD` | Quay.io robot account password |
| `QUAY_ORG`      | Quay.io org or username |

Then tag a release to trigger a build:

```bash
git tag v1.0.0
git push origin v1.0.0
```
