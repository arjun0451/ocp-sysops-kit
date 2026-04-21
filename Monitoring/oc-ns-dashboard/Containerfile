# =============================================================================
# Stage 1 — Builder (install deps as root, no oc binary needed)
# =============================================================================
FROM registry.access.redhat.com/ubi9/nodejs-20:latest AS builder

USER root
WORKDIR /build

# ── Node dependencies ─────────────────────────────────────────────────────────
# npm install (not ci) — no package-lock.json required
COPY package.json ./
RUN npm install --ignore-scripts --production && \
    echo "npm install complete"

# ── Application source ────────────────────────────────────────────────────────
COPY src/    ./src/
COPY public/ ./public/

# =============================================================================
# Stage 2 — Runtime (linux/amd64 for OpenShift)
# =============================================================================
FROM --platform=linux/amd64 registry.access.redhat.com/ubi9/nodejs-20-minimal:latest AS runtime

LABEL name="ocp-ns-dashboard" \
      version="3.0.0" \
      description="OpenShift Namespace & Workload Dashboard — Red Hat SRE Tooling" \
      maintainer="Platform SRE Team" \
      io.k8s.description="Tile-based OCP namespace workload visibility dashboard" \
      io.k8s.display-name="OCP Namespace Dashboard" \
      io.openshift.tags="ocp,dashboard,sre,monitoring,k8s-api"

USER root
WORKDIR /app

# ── Copy app from builder ─────────────────────────────────────────────────────
COPY --from=builder /build/node_modules ./node_modules
COPY --from=builder /build/src          ./src
COPY --from=builder /build/public       ./public
COPY --from=builder /build/package.json ./package.json

# ── Permissions (OCP arbitrary-user SCC compatible) ───────────────────────────
RUN chown -R 1001:0 /app && \
    chmod -R g=u /app

USER 1001

ENV PORT=3000 \
    NODE_ENV=production

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/healthz', r => process.exit(r.statusCode===200?0:1))"

CMD ["node", "src/server.js"]
