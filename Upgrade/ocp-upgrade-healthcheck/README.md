# ocp-upgrade-healthcheck

OpenShift upgrade pre-flight health check dashboard.  
Runs as a container — no Node.js, no `oc`, no `jq` needed on the host.

```
Image includes:  oc CLI  |  jq  |  health check script  |  Node.js dashboard
Auth at runtime: OC_TOKEN + OC_SERVER env vars
```

---

## Contents

```
.
├── Containerfile                          # Multi-stage build (alpine + node:20-slim)
├── entrypoint.sh                          # Auth setup, auto-run trigger
├── run.sh                                 # Build + run helper
├── prepare-bins.sh                        # Download oc + jq binaries (run once)
├── app/
│   ├── server.js                          # Express dashboard API
│   ├── package.json
│   └── public/index.html                  # Dashboard UI
├── scripts/
│   └── ocp-upgrade-healthcheck-v6.sh      # Embedded health check script
├── bin/                                   # Drop oc + jq binaries here before build
└── docs/
    ├── build.md                           # Build guide
    └── run.md                             # Run guide
```

---

## Quick start

```bash
# 1. Download binaries (once, internet-connected machine only)
./prepare-bins.sh

# 2. Build
podman build -t ocp-upgrade-healthcheck:latest -f Containerfile .

# 3. Run
./run.sh --token sha256~<token> --server https://api.<cluster>:6443
```

Open **http://localhost:8080**

---

## Docs

- [Build guide](docs/build.md) — local, disconnected/air-gapped, push to registry
- [Run guide](docs/run.md) — local, remote server, disconnected environments

---

## License

Apache 2.0
