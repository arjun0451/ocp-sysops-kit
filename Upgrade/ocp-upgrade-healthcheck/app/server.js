#!/usr/bin/env node
// =============================================================================
// OCP Upgrade Health Check Dashboard — server.js v3
//
// Architecture:
//   - Script runs as a child process with oc/jq available (bundled in image)
//   - Output is captured line-by-line into an in-memory structured log
//   - Each line is parsed into: { raw, html, ts, checkIdx, status }
//   - Dashboard polls /api/results every 2s — no SSE race conditions
//   - /api/run starts the script; /api/results returns everything seen so far
//   - Auth status, tool paths all read from /tmp/auth-status.json written by entrypoint
// =============================================================================

'use strict';

const express  = require('express');
const path     = require('path');
const fs       = require('fs');
const os       = require('os');
const { spawn } = require('child_process');

// ── Config ────────────────────────────────────────────────────────────────────
const PORT         = parseInt(process.env.PORT || '8080', 10);
const SCRIPT_PATH  = process.env.SCRIPT_PATH  || '/app/scripts/ocp-upgrade-healthcheck-v6.sh';
// Resolve a writable artifact base — fall back to /tmp/artifacts if mounted dir isn't writable
function resolveArtifactBase() {
  const candidates = [
    process.env.ARTIFACT_BASE || '/artifacts',
    '/tmp/artifacts',
    path.join(os.tmpdir(), 'ocp-artifacts'),
  ];
  for (const dir of candidates) {
    try {
      fs.mkdirSync(dir, { recursive: true });
      // Verify we can actually write
      const probe = path.join(dir, '.write-probe');
      fs.writeFileSync(probe, 'ok');
      fs.unlinkSync(probe);
      return dir;
    } catch (_) { /* try next */ }
  }
  return os.tmpdir(); // last resort
}
const ARTIFACT_BASE = resolveArtifactBase();
console.log(`[server] Artifacts : ${ARTIFACT_BASE}`);
const AUTH_FILE    = '/tmp/auth-status.json';

// ── ANSI → HTML converter ─────────────────────────────────────────────────────
// Handles all codes the health check script emits
const ANSI_CODES = {
  '0': null, '22': null,          // reset
  '1': 'b',                       // bold
  '31': 'r', '32': 'g', '33': 'y',
  '34': 'bl', '35': 'm', '36': 'c',
  '97': 'w', '38;5;208': 'o',
};

function ansiToHtml(raw) {
  if (!raw) return '';
  let result = '';
  let depth  = 0;
  let i = 0;

  while (i < raw.length) {
    if (raw.charCodeAt(i) === 27 && raw[i + 1] === '[') {
      const end = raw.indexOf('m', i + 2);
      if (end !== -1) {
        const code = raw.slice(i + 2, end);
        const cls  = ANSI_CODES[code];
        if (code === '0' || code === '22') {
          result += '</span>'.repeat(depth);
          depth = 0;
        } else if (cls !== undefined && cls !== null) {
          result += `<span class="${cls}">`;
          depth++;
        }
        i = end + 1;
        continue;
      }
    }
    const c = raw[i];
    result += c === '<' ? '&lt;' : c === '>' ? '&gt;' : c === '&' ? '&amp;' : c;
    i++;
  }
  return result + '</span>'.repeat(depth);
}

// ── Parse line metadata from raw output ───────────────────────────────────────
function parseLineMeta(raw) {
  // Strip ANSI for analysis
  const clean = raw.replace(/\x1b\[[0-9;]*m/g, '').trim();

  // Detect check section header: [01/22]
  const secMatch = clean.match(/^\[(\d{2})\/22\]/);
  if (secMatch) {
    return { type: 'section_start', idx: secMatch[1], clean };
  }

  // Detect skipped section
  if (clean.includes('SKIPPED:')) {
    const sm = clean.match(/\[(\d{2})\/22\]/);
    if (sm) return { type: 'section_skip', idx: sm[1], clean };
  }

  // Detect summary block
  if (clean.includes('CHECK SUMMARY')) return { type: 'summary_start', clean };

  // Detect result line from summary
  const failMatch = clean.match(/Failures\s*:\s*(\d+)/);
  const warnMatch = clean.match(/Warnings\s*:\s*(\d+)/);
  if (failMatch) return { type: 'stat_fail', count: parseInt(failMatch[1], 10), clean };
  if (warnMatch) return { type: 'stat_warn', count: parseInt(warnMatch[1], 10), clean };

  // Detect overall result
  if (clean.includes('RESULT: PASS'))    return { type: 'result', result: 'pass', clean };
  if (clean.includes('RESULT: WARNING')) return { type: 'result', result: 'warn', clean };
  if (clean.includes('RESULT: FAILED'))  return { type: 'result', result: 'fail', clean };

  // Detect line-level signals for section colouring
  if (clean.startsWith('[X]') || clean.includes('mark_fail')) return { type: 'line_fail', clean };
  if (clean.startsWith('[!]') || clean.includes('mark_warn')) return { type: 'line_warn', clean };
  if (clean.startsWith('[OK]'))                                return { type: 'line_ok',   clean };

  return { type: 'text', clean };
}

// ── Run state ─────────────────────────────────────────────────────────────────
function freshState() {
  return {
    running:     false,
    pid:         null,
    startTime:   null,
    endTime:     null,
    exitCode:    null,
    result:      null,       // 'pass' | 'warn' | 'fail'
    totalFails:  null,
    totalWarns:  null,
    lines:       [],         // { ts, raw, html, meta }
    sections:    [],         // { idx, label, startLine, status }
    artifactDir: null,
    runId:       null,
  };
}

let S = freshState();
let activeProc = null;
let lineBuf    = '';

// Section labels map
const SECTION_LABELS = {
  '01':'Cluster Version',      '02':'Cluster Operators',
  '03':'OLM Operators',        '04':'Node Status',
  '05':'Node Resources',       '06':'MCP + MC Match',
  '07':'Control Plane Labels', '08':'API / ETCD Pods',
  '09':'ETCD Conditions',      '10':'ETCD etcdctl',
  '11':'Webhooks',             '12':'Deprecated APIs',
  '13':'TLS Certificates',     '14':'Pending CSRs',
  '15':'Critical Alerts',      '16':'Workload Health',
  '17':'PDB Analysis',         '18':'PVC / PV Health',
  '19':'Disk Usage',           '20':'Events',
  '21':'Route Health',         '22':'EgressIP',
};

// ── Process incoming output chunk ─────────────────────────────────────────────
function ingestChunk(chunk) {
  lineBuf += chunk.toString().replace(/\r/g, '');
  const parts = lineBuf.split('\n');
  lineBuf = parts.pop();
  parts.forEach(processLine);
}

function processLine(raw) {
  const html = ansiToHtml(raw);
  const meta = parseLineMeta(raw);
  const entry = { ts: Date.now(), raw, html, meta };
  S.lines.push(entry);

  const lineIdx = S.lines.length - 1;

  switch (meta.type) {
    case 'section_start': {
      // Close previous open section
      const prev = S.sections.find(s => s.status === 'running');
      if (prev && prev.status === 'running') prev.status = 'pass';
      S.sections.push({
        idx:       meta.idx,
        label:     SECTION_LABELS[meta.idx] || `Check ${meta.idx}`,
        startLine: lineIdx,
        status:    'running',
      });
      break;
    }
    case 'section_skip': {
      S.sections.push({
        idx:       meta.idx,
        label:     SECTION_LABELS[meta.idx] || `Check ${meta.idx}`,
        startLine: lineIdx,
        status:    'skip',
      });
      break;
    }
    case 'summary_start': {
      // Close last running section
      const prev = S.sections.find(s => s.status === 'running');
      if (prev) prev.status = 'pass';
      break;
    }
    case 'stat_fail':
      S.totalFails = meta.count;
      break;
    case 'stat_warn':
      S.totalWarns = meta.count;
      break;
    case 'result':
      S.result = meta.result;
      break;
    case 'line_fail': {
      const cur = [...S.sections].reverse().find(s => s.status === 'running');
      if (cur) cur.status = 'fail';
      break;
    }
    case 'line_warn': {
      const cur = [...S.sections].reverse().find(s => s.status === 'running');
      if (cur && cur.status === 'running') cur.status = 'warn';
      break;
    }
  }
}

// ── Run script ────────────────────────────────────────────────────────────────
function runScript() {
  if (S.running) return { error: 'Already running' };

  const runId      = Date.now().toString();
  const artifactDir = path.join(
    ARTIFACT_BASE,
    `run-${new Date().toISOString().slice(0,19).replace(/[T:]/g, '-')}`
  );
  // mkdirSync can fail if /artifacts volume is owned by a different UID
  // In that case fall back to a writable temp path
  let finalArtifactDir = artifactDir;
  try {
    fs.mkdirSync(artifactDir, { recursive: true });
  } catch (mkErr) {
    finalArtifactDir = path.join(os.tmpdir(), 'ocp-artifacts',
      `run-${new Date().toISOString().slice(0,19).replace(/[T:]/g, '-')}`);
    console.warn(`[run] ${artifactDir} not writable (${mkErr.code}) — using ${finalArtifactDir}`);
    fs.mkdirSync(finalArtifactDir, { recursive: true });
  }

  S = freshState();
  S.running    = true;
  S.startTime  = new Date().toISOString();
  S.runId      = runId;
  S.artifactDir = finalArtifactDir;
  lineBuf      = '';

  const env = {
    ...process.env,
    PATH:         process.env.PATH || '/usr/local/bin:/usr/bin:/bin',
    ARTIFACT_DIR: finalArtifactDir,
    TERM:         'xterm-256color',
    COLORTERM:    'truecolor',
    // Force color even without TTY — our script checks -t 1
    // We override that check via CLICOLOR_FORCE
    CLICOLOR_FORCE: '1',
    HOME:         process.env.HOME || '/root',
  };

  // Preserve KUBECONFIG if set
  if (process.env.KUBECONFIG) env.KUBECONFIG = process.env.KUBECONFIG;

  const scriptToRun = fs.existsSync(SCRIPT_PATH) ? SCRIPT_PATH
    : '/app/scripts/ocp-upgrade-healthcheck-v6.sh';

  // Patch the script on-the-fly to force color output:
  // The script checks `[[ -t 1 ]]` for TTY — pipe breaks that.
  // We pass a wrapper that sources the script with forced color vars.
  const wrapper = `
    export CLICOLOR_FORCE=1
    export FORCE_COLOR=1
    # Override the TTY check in the script by pre-setting color vars
    bash "${scriptToRun}"
  `;

  activeProc = spawn('bash', ['-c', wrapper], { env, shell: false });
  S.pid = activeProc.pid;

  activeProc.stdout.on('data', ingestChunk);
  activeProc.stderr.on('data', ingestChunk);

  activeProc.on('close', code => {
    // Flush buffer
    if (lineBuf.trim()) { processLine(lineBuf); lineBuf = ''; }

    // Close any still-running sections
    S.sections.forEach(s => { if (s.status === 'running') s.status = 'pass'; });

    S.running  = false;
    S.exitCode = code;
    S.endTime  = new Date().toISOString();
    activeProc = null;

    // Derive result from exit code if not parsed from output
    if (!S.result) {
      S.result = code === 0 ? 'pass' : code === 1 ? 'warn' : 'fail';
    }

    // Write summary JSON artifact
    const summary = {
      runId, exitCode: code, result: S.result,
      startTime: S.startTime, endTime: S.endTime,
      totalFails: S.totalFails, totalWarns: S.totalWarns,
      sections: S.sections.map(({ idx, label, status }) => ({ idx, label, status })),
    };
    fs.writeFileSync(
      path.join(artifactDir, 'summary.json'),
      JSON.stringify(summary, null, 2)
    );

    console.log(`[run] Completed. Exit=${code} Result=${S.result} Lines=${S.lines.length}`);
  });

  activeProc.on('error', err => {
    processLine(`ERROR launching script: ${err.message}`);
    S.running  = false;
    S.exitCode = 1;
    S.result   = 'fail';
    activeProc = null;
  });

  console.log(`[run] Started PID=${S.pid} script=${scriptToRun}`);
  return { ok: true, runId, artifactDir };
}

// ── Express app ───────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Auth info (written by entrypoint.sh)
app.get('/api/auth', (_req, res) => {
  try {
    const raw = fs.readFileSync(AUTH_FILE, 'utf8');
    res.json(JSON.parse(raw));
  } catch (_) {
    res.json({ ok: false, method: 'none', user: '', server: '', script: SCRIPT_PATH });
  }
});

// Server + run status
app.get('/api/status', (_req, res) => {
  res.json({
    running:      S.running,
    exitCode:     S.exitCode,
    result:       S.result,
    startTime:    S.startTime,
    endTime:      S.endTime,
    lineCount:    S.lines.length,
    sectionCount: S.sections.length,
    scriptExists: fs.existsSync(SCRIPT_PATH),
    hostname:     os.hostname(),
    platform:     os.platform(),
  });
});

// Full results — lines since `from` index + section map
// Poll this from the browser every 2s
app.get('/api/results', (req, res) => {
  const from = parseInt(req.query.from || '0', 10);
  res.json({
    running:     S.running,
    exitCode:    S.exitCode,
    result:      S.result,
    startTime:   S.startTime,
    endTime:     S.endTime,
    totalFails:  S.totalFails,
    totalWarns:  S.totalWarns,
    lineCount:   S.lines.length,
    sections:    S.sections,            // always send full section list
    lines:       S.lines.slice(from).map(l => ({ ts: l.ts, html: l.html, raw: l.raw })),
    artifactDir: S.artifactDir,
  });
});

// Trigger run
app.post('/api/run', (_req, res) => {
  const r = runScript();
  if (r.error) return res.status(409).json(r);
  res.json(r);
});

// Kill
app.post('/api/kill', (_req, res) => {
  if (!S.running || !activeProc) return res.status(400).json({ error: 'Nothing running' });
  activeProc.kill('SIGTERM');
  res.json({ ok: true });
});

// Artifacts list
app.get('/api/artifacts', (_req, res) => {
  const dir = S.artifactDir;
  if (!dir || !fs.existsSync(dir)) return res.json({ files: [] });
  const files = fs.readdirSync(dir)
    .filter(f => !f.startsWith('.'))
    .map(f => {
      const fp = path.join(dir, f);
      const st = fs.statSync(fp);
      return { name: f, size: st.size, mtime: st.mtime };
    })
    .sort((a, b) => a.name.localeCompare(b.name));
  res.json({ dir, files });
});

// Artifact download
app.get('/api/artifacts/:name', (req, res) => {
  const dir = S.artifactDir;
  if (!dir) return res.status(404).json({ error: 'No artifacts' });
  const fp = path.join(dir, path.basename(req.params.name));
  if (!fp.startsWith(dir) || !fs.existsSync(fp))
    return res.status(404).json({ error: 'File not found' });
  res.download(fp);
});

// Download full run log as plain text
app.get('/api/download/log', (_req, res) => {
  res.setHeader('Content-Type', 'text/plain; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="ocp-healthcheck-${S.runId || 'log'}.txt"`);
  const text = S.lines.map(l => l.raw).join('\n');
  res.send(text);
});

// Download summary as JSON
app.get('/api/download/summary', (_req, res) => {
  res.setHeader('Content-Disposition', `attachment; filename="summary-${S.runId || 'run'}.json"`);
  res.json({
    runId: S.runId, exitCode: S.exitCode, result: S.result,
    startTime: S.startTime, endTime: S.endTime,
    totalFails: S.totalFails, totalWarns: S.totalWarns,
    sections: S.sections,
  });
});

// ── Boot ──────────────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  console.log(`[server] OCP Health Check Dashboard v3 — port ${PORT}`);
  console.log(`[server] Script : ${SCRIPT_PATH}`);
  console.log(`[server] Ready  : http://localhost:${PORT}`);
});
