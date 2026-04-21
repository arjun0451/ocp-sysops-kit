# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an **OpenShift Namespace Dashboard** - a Node.js/Express application that provides a web interface for monitoring Kubernetes/OpenShift namespaces, pods, deployments, and statefulsets. It runs in-cluster using a service account with read-only RBAC permissions.

## Development Commands

```bash
# Start the server (requires K8s cluster access or mock data)
npm start

# Development with auto-reload (Node.js >= 18 with --watch flag)
npm run dev

# Build container image
podman build -t ocp-ns-dashboard:latest -f Containerfile .

# Deploy to OpenShift (option 1: flat manifest)
oc apply -f k8s/all-in-one.yaml

# Deploy to OpenShift (option 2: Helm)
helm install ocp-ns-dashboard ./helm/ocp-ns-dashboard
```

## Architecture

### Backend (`src/server.js`)
- **Express server** serving static files and API endpoint `/api/dashboard`
- **In-cluster Kubernetes API access** via service account token at `/var/run/secrets/kubernetes.io/serviceaccount/token`
- **APIs queried**: `/api/v1/namespaces`, `/api/v1/pods`, `/apis/apps/v1/deployments`, `/apis/apps/v1/statefulsets`, `/api/v1/nodes`
- **System namespace exclusion**: `openshift`, `default`, `kube-system`, `kube-public`, `kube-node-lease`, and anything starting with `openshift-` or `kube-`
- **Configurable appgroup label** via `APP_GROUP_LABEL` env var (default: `appgroup`)
- **Sentinel value** for unlabeled namespaces: `NO_LABEL_VALUE = 'no label'` (was `'default'`)

### Frontend (`public/index.html`)
- Single-page HTML dashboard with embedded CSS and JavaScript
- **Filter bar** with namespace search, health chips, sort options, advanced pod filters, and collapsible AppGroup section
- **Summary tiles** showing cluster-wide stats (namespaces, deployments, statefulsets, nodes, pod counts by status)
- **Namespace cards** displaying pod health bars, workload counts, expandable deployment/statefulset lists, and sortable pod tables
- **AppGroup filter section**: Collapsible dropdown with executive summary tiles for selected label

### Key Data Structures

**Namespace Tile (from `/api/dashboard`):**
```javascript
{
  namespace: "string",
  health: "healthy|warning|critical",
  appGroup: "string",           // label value or NO_LABEL_VALUE
  appGroupLabel: "appgroup",    // configured label key
  labels: [{key, value}],       // non-system labels only
  pods: [...],
  podSummary: { total, running, pending, notReady, error, succeeded, ... },
  deployments: [...],
  statefulsets: [...]
}
```

**Filter State (global `F` object):**
```javascript
{
  ns: [],           // namespace search terms (array)
  pod: '',          // pod name filter string
  health: 'all',    // health chip filter
  ps: 'all',        // pod status chip filter
  node: 'all',      // node filter
  appGroup: 'all'   // app group filter
}
```

### Deployment Configuration

**Container Image:** `quay.io/arjunareddy/backup/ocp-health-dashboard:v5`

**RBAC Permissions (read-only):**
- `namespaces`, `pods`, `nodes`: get, list, watch
- `deployments`, `statefulsets` (apps API group): get, list, watch

**Security:** Runs under `restricted-v2` SCC. DO NOT set `runAsUser` or `fsGroup` - OCP injects namespace UID automatically. Hardcoding UIDs causes "must be in ranges" admission errors.

**Environment Variables:**
- `PORT`: Server port (default: 3000)
- `APP_GROUP_LABEL`: Label key for grouping namespaces (default: `appgroup`)
- `NO_LABEL_VALUE`: Sentinel value for unlabeled namespaces (default: `'no label'`)

### Frontend Filter Logic

**Namespace-level filters:**
- Namespace name search (comma-separated, OR logic)
- Health status (`healthy`, `warning`, `critical`)
- AppGroup label

**Pod-level filters (when appGroup is NOT filtered):**
- Pod status chips filter which namespaces are shown (must have matching pods)

**Pod-level filters (always applied to pod lists within cards):**
- Pod name search
- Pod status class
- Node assignment

## Important Implementation Notes

1. **AppGroup Filter Independence:** When `F.appGroup !== 'all'`, namespaces are NOT filtered by pod status - all namespaces with the selected label are shown. Pod status filters only apply to pods within those namespace cards.

2. **Frontend State Management:** The global `F` object tracks all filter state. `renderDash()` re-renders the entire dashboard (including dropdowns), while `renderTiles()` just filters and re-renders the namespace grid.

3. **Color Mapping:** `agColorMap` maintains stable color assignment for appgroup values using `AG_COLORS` array (7 colors: blue, green, yellow, purple, orange, red, gray).

4. **Pod Status Classification:** Custom logic in `classifyPod()` converts K8s pod status to dashboard status classes (`running`, `pending`, `not-ready`, `error`, `crashloop`, `oomkilled`, `imagepull`, `configerror`, `unschedulable`, `succeeded`).

## File Structure

```
├── src/server.js           # Express server, K8s API integration
├── public/index.html       # Complete frontend (CSS + JS + HTML)
├── package.json            # Node dependencies (express only)
├── Containerfile           # Multi-stage build (ubi9/nodejs-20)
├── k8s/
│   ├── all-in-one.yaml     # Flat manifest for oc apply
│   ├── manifests.yaml      # Base k8s resources
│   └── rollback.yaml       # Rollback/deletion resources
└── helm/
    └── ocp-ns-dashboard/   # Helm chart
        ├── Chart.yaml
        ├── values.yaml     # Default configuration
        └── templates/      # K8s resource templates
```
