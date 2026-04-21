/**
 * OCP Namespace Dashboard — Server v4.0.0
 * OpenShift Workload Monitoring | Native K8s HTTPS API
 *
 * v4 additions:
 *   - Namespace labels preserved and returned per tile
 *   - App-group label extracted (configurable via APP_GROUP_LABEL env)
 *   - appGroups index returned at top level for frontend filter building
 */

'use strict';

const express = require('express');
const https   = require('https');
const fs      = require('fs');
const path    = require('path');

const app  = express();
const PORT = process.env.PORT || 3000;

// ─── In-cluster config ────────────────────────────────────────────
const SA_TOKEN_PATH = '/var/run/secrets/kubernetes.io/serviceaccount/token';
const SA_CA_PATH    = '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt';
const K8S_HOST      = process.env.KUBERNETES_SERVICE_HOST || 'kubernetes.default.svc';
const K8S_PORT      = process.env.KUBERNETES_SERVICE_PORT || '443';

// ─── App-group label key ──────────────────────────────────────────
// Default: appgroup  →  matches labels like  appgroup=dev / appgroup=uat
// Override via env:  APP_GROUP_LABEL=environment  for  environment=prod
const APP_GROUP_LABEL = process.env.APP_GROUP_LABEL || 'appgroup';

// Sentinel value used when a namespace has no app-group label
const NO_LABEL_VALUE = 'no label'; // unlabelled namespaces fall into 'no label' category

// ─── System namespace exclusion ───────────────────────────────────
const SYS_EXACT = new Set([
  'openshift','default','kube-system','kube-public','kube-node-lease',
]);
function isSystem(ns) {
  if (SYS_EXACT.has(ns)) return true;
  return ns.startsWith('openshift-') || ns.startsWith('kube-');
}

// ─── K8s API request ─────────────────────────────────────────────
function k8s(apiPath) {
  return new Promise((resolve, reject) => {
    let token = '', ca;
    try { token = fs.readFileSync(SA_TOKEN_PATH, 'utf8').trim(); } catch {}
    try { ca    = fs.readFileSync(SA_CA_PATH); }                  catch {}

    const opts = {
      hostname: K8S_HOST,
      port:     K8S_PORT,
      path:     apiPath,
      method:   'GET',
      headers:  { Authorization: `Bearer ${token}`, Accept: 'application/json' },
      ...(ca ? { ca } : { rejectUnauthorized: false }),
    };

    const req = https.request(opts, res => {
      let buf = '';
      res.on('data', c => buf += c);
      res.on('end', () => {
        try { resolve(JSON.parse(buf)); }
        catch (e) { reject(new Error(`JSON parse: ${e.message}`)); }
      });
    });
    req.on('error', reject);
    req.setTimeout(12000, () => req.destroy(new Error('K8s API timeout')));
    req.end();
  });
}

// ─── Pod age ─────────────────────────────────────────────────────
function podAge(ts) {
  if (!ts) return '—';
  const ms = Date.now() - new Date(ts).getTime();
  const m  = Math.floor(ms / 60000);
  if (m < 60)  return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24)  return `${h}h`;
  return `${Math.floor(h / 24)}d`;
}

// ─── Pod status classifier ────────────────────────────────────────
function classifyPod(pod) {
  const phase      = pod.status?.phase || 'Unknown';
  const conditions = pod.status?.conditions || [];
  const csList     = pod.status?.containerStatuses || [];
  const initList   = pod.status?.initContainerStatuses || [];
  const allCS      = [...csList, ...initList];

  const waitingReason = () => {
    for (const cs of allCS) { const r = cs.state?.waiting?.reason; if (r) return r; }
    return null;
  };
  const reason = waitingReason();

  if (reason === 'CrashLoopBackOff')
    return { statusClass: 'crashloop',    statusLabel: 'CrashLoopBackOff', severity: 2 };
  if (reason === 'OOMKilled' || allCS.some(c => c.lastState?.terminated?.reason === 'OOMKilled'))
    return { statusClass: 'oomkilled',    statusLabel: 'OOMKilled',        severity: 2 };
  if (reason === 'ErrImagePull' || reason === 'ImagePullBackOff')
    return { statusClass: 'imagepull',    statusLabel: reason,             severity: 2 };
  if (reason === 'InvalidImageName')
    return { statusClass: 'imagepull',    statusLabel: 'InvalidImageName', severity: 2 };
  if (['CreateContainerConfigError','CreateContainerError','RunContainerError','ContainerCannotRun'].includes(reason))
    return { statusClass: 'configerror',  statusLabel: reason,             severity: 2 };
  if (phase === 'Failed')
    return { statusClass: 'failed',       statusLabel: 'Failed',           severity: 2 };
  if (phase === 'Succeeded')
    return { statusClass: 'succeeded',    statusLabel: 'Succeeded',        severity: 0 };
  if (phase === 'Unknown')
    return { statusClass: 'unknown',      statusLabel: 'Unknown',          severity: 1 };
  if (phase === 'Pending') {
    const sched = conditions.find(c => c.type === 'PodScheduled');
    if (sched?.status === 'False' && sched.reason === 'Unschedulable')
      return { statusClass: 'unschedulable', statusLabel: 'Unschedulable', severity: 2 };
    if (reason === 'ContainerCreating') return { statusClass: 'pending', statusLabel: 'Creating',     severity: 1 };
    if (reason === 'PodInitializing')   return { statusClass: 'pending', statusLabel: 'Initializing', severity: 1 };
    return { statusClass: 'pending', statusLabel: 'Pending', severity: 1 };
  }
  if (phase === 'Running') {
    if (pod.metadata?.deletionTimestamp)
      return { statusClass: 'terminating', statusLabel: 'Terminating', severity: 1 };
    const ready = csList.length > 0 && csList.every(c => c.ready);
    if (!ready) return { statusClass: 'not-ready', statusLabel: 'NotReady', severity: 1 };
    return { statusClass: 'running', statusLabel: 'Running', severity: 0 };
  }
  return { statusClass: 'unknown', statusLabel: phase || 'Unknown', severity: 1 };
}

const STATUS_GROUP = {
  running: 'running', pending: 'pending', terminating: 'pending',
  'not-ready': 'not-ready', unschedulable: 'error',
  failed: 'error', crashloop: 'error', oomkilled: 'error',
  imagepull: 'error', configerror: 'error', unknown: 'error',
  succeeded: 'succeeded',
};

// ─── Data aggregation ─────────────────────────────────────────────
async function getDashboardData() {
  const [nsR, podR, depR, stsR, nodeR] = await Promise.allSettled([
    k8s('/api/v1/namespaces'),
    k8s('/api/v1/pods'),
    k8s('/apis/apps/v1/deployments'),
    k8s('/apis/apps/v1/statefulsets'),
    k8s('/api/v1/nodes'),
  ]);

  // ── Namespace objects — keep full metadata for labels ─────────────
  const nsItems = nsR.status === 'fulfilled'
    ? (nsR.value.items || []).filter(n => !isSystem(n.metadata.name))
    : [];
  nsItems.sort((a, b) => a.metadata.name.localeCompare(b.metadata.name));

  const allPods  = podR.status  === 'fulfilled' ? (podR.value.items  || []) : [];
  const allDeps  = depR.status  === 'fulfilled' ? (depR.value.items  || []) : [];
  const allSTS   = stsR.status  === 'fulfilled' ? (stsR.value.items  || []) : [];
  const allNodes = nodeR.status === 'fulfilled' ? (nodeR.value.items || []) : [];

  // ── Node map ─────────────────────────────────────────────────────
  const nodeMap = {};
  allNodes.forEach(n => {
    const lbl  = n.metadata.labels || {};
    const cond = (n.status?.conditions || []).find(c => c.type === 'Ready');
    nodeMap[n.metadata.name] = {
      name:   n.metadata.name,
      role:   lbl['node-role.kubernetes.io/master'] !== undefined ||
              lbl['node-role.kubernetes.io/control-plane'] !== undefined
                ? 'control-plane' : 'worker',
      status: cond?.status === 'True' ? 'Ready' : 'NotReady',
      zone:   lbl['topology.kubernetes.io/zone'] ||
              lbl['failure-domain.beta.kubernetes.io/zone'] || 'N/A',
    };
  });

  // ── Per-namespace tiles (with label data) ─────────────────────────
  const appGroupSet = new Set();

  const namespaceTiles = nsItems.map(nsObj => {
    const ns     = nsObj.metadata.name;
    const labels = nsObj.metadata.labels || {};

    // Extract app-group label value; fall back to sentinel
    const appGroup = labels[APP_GROUP_LABEL] || NO_LABEL_VALUE;
    appGroupSet.add(appGroup);  // 'default' group included like any other

    // Collect all namespace labels (excluding system/k8s internals) for display
    const displayLabels = Object.entries(labels)
      .filter(([k]) => !k.startsWith('kubernetes.io/') && !k.startsWith('k8s.io/'))
      .map(([k, v]) => ({ key: k, value: v }));

    const pods = allPods.filter(p => p.metadata.namespace === ns);
    const deps = allDeps.filter(d => d.metadata.namespace === ns);
    const sts  = allSTS.filter(s  => s.metadata.namespace === ns);

    const podDetails = pods.map(p => {
      const { statusClass, statusLabel, severity } = classifyPod(p);
      const csList   = p.status?.containerStatuses || [];
      const allCS    = [...csList, ...(p.status?.initContainerStatuses || [])];
      const restarts = allCS.reduce((s, c) => s + (c.restartCount || 0), 0);
      const nodeName = p.spec?.nodeName || 'Unscheduled';
      return {
        name: p.metadata.name, phase: p.status?.phase || 'Unknown',
        statusClass, statusLabel, severity,
        group: STATUS_GROUP[statusClass] || 'error',
        restarts, nodeName,
        nodeRole: nodeMap[nodeName]?.role || 'unknown',
        nodeZone: nodeMap[nodeName]?.zone || 'N/A',
        age:  podAge(p.metadata.creationTimestamp),
        ready: csList.length > 0 && csList.every(c => c.ready),
        containers: csList.map(c => ({ name: c.name, ready: c.ready, restarts: c.restartCount || 0 })),
      };
    });

    const summary = {
      total:         podDetails.length,
      running:       podDetails.filter(p => p.group === 'running').length,
      pending:       podDetails.filter(p => p.group === 'pending').length,
      notReady:      podDetails.filter(p => p.group === 'not-ready').length,
      error:         podDetails.filter(p => p.group === 'error').length,
      succeeded:     podDetails.filter(p => p.group === 'succeeded').length,
      crashloop:     podDetails.filter(p => p.statusClass === 'crashloop').length,
      oomkilled:     podDetails.filter(p => p.statusClass === 'oomkilled').length,
      imagepull:     podDetails.filter(p => p.statusClass === 'imagepull').length,
      configerror:   podDetails.filter(p => p.statusClass === 'configerror').length,
      failed:        podDetails.filter(p => p.statusClass === 'failed').length,
      unschedulable: podDetails.filter(p => p.statusClass === 'unschedulable').length,
    };

    const health =
      summary.error > 0 ? 'critical' :
      (summary.pending > 0 || summary.notReady > 0) ? 'warning' : 'healthy';

    return {
      namespace: ns,
      health,
      // ── Label data ─────────────────────────────────────────────
      appGroup,                          // e.g. "dev" / "uat" / "__no_label__"
      appGroupLabel: APP_GROUP_LABEL,    // e.g. "appgroup" — for display
      labels: displayLabels,             // all non-system labels for tooltip
      pods: podDetails,
      podSummary: summary,
      deployments: deps.map(d => ({
        name: d.metadata.name, desired: d.spec.replicas ?? 0,
        ready: d.status?.readyReplicas ?? 0, available: d.status?.availableReplicas ?? 0,
        health: (d.status?.readyReplicas ?? 0) >= (d.spec.replicas ?? 0) ? 'ok' : 'degraded',
      })),
      statefulsets: sts.map(s => ({
        name: s.metadata.name, desired: s.spec.replicas ?? 0,
        ready: s.status?.readyReplicas ?? 0,
        health: (s.status?.readyReplicas ?? 0) >= (s.spec.replicas ?? 0) ? 'ok' : 'degraded',
      })),
    };
  });

  // ── Global summary ────────────────────────────────────────────────
  const userPods = allPods.filter(p => !isSystem(p.metadata.namespace));
  const userDeps = allDeps.filter(d => !isSystem(d.metadata.namespace));
  const userSTS  = allSTS.filter(s  => !isSystem(s.metadata.namespace));

  const globalPodStatus = { running:0, pending:0, notReady:0, error:0, succeeded:0 };
  namespaceTiles.forEach(t => {
    globalPodStatus.running   += t.podSummary.running;
    globalPodStatus.pending   += t.podSummary.pending;
    globalPodStatus.notReady  += t.podSummary.notReady;
    globalPodStatus.error     += t.podSummary.error;
    globalPodStatus.succeeded += t.podSummary.succeeded;
  });

  // Sorted list of distinct appGroup values for filter chip rendering
  const appGroups = [...appGroupSet].sort();

  return {
    timestamp: new Date().toISOString(),
    source:    'k8s-api',
    appGroupLabel: APP_GROUP_LABEL,   // key name used — so UI can label the filter
    appGroups,                         // distinct values found e.g. ["dev","prod","uat"]
    noLabelValue: NO_LABEL_VALUE,      // 'default' — unlabelled namespaces bucket
    summary: {
      namespaces:   nsItems.length,
      deployments:  userDeps.length,
      statefulsets: userSTS.length,
      pods:         userPods.length,
      nodes:        allNodes.length,
      nodesReady:   Object.values(nodeMap).filter(n => n.status === 'Ready').length,
      ...globalPodStatus,
    },
    nodes: Object.values(nodeMap),
    namespaceTiles,
    errors: {
      namespaces: nsR.status  === 'rejected' ? nsR.reason?.message  : null,
      pods:       podR.status === 'rejected' ? podR.reason?.message : null,
      deploys:    depR.status === 'rejected' ? depR.reason?.message : null,
      nodes:      nodeR.status === 'rejected' ? nodeR.reason?.message : null,
    },
  };
}

// ─── Routes ──────────────────────────────────────────────────────
app.use(express.static(path.join(__dirname, '../public')));

app.get('/api/dashboard', async (_req, res) => {
  try {
    res.json({ success: true, data: await getDashboardData() });
  } catch (err) {
    console.error('[/api/dashboard]', err.message);
    res.status(500).json({ success: false, error: err.message });
  }
});

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));
app.get('*',        (_req, res) => res.sendFile(path.join(__dirname, '../public/index.html')));

app.listen(PORT, () => {
  console.log(`[OCP Dashboard] v4.0.0 | Port: ${PORT} | AppGroupLabel: ${APP_GROUP_LABEL}`);
  console.log(`[OCP Dashboard] API: https://${K8S_HOST}:${K8S_PORT}`);
});
