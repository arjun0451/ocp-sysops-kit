#!/usr/bin/env node
// =============================================================================
// OCP Upgrade Health Check Dashboard — server.js  v2
// Hosts a web UI that reads artifact files produced by the shell script.
// The shell script runs separately on the terminal.
// This server just watches the artifact directory and serves the UI.
//
// Usage:
//   node server.js [--port 8080] [--artifacts /tmp/ocp-upgrade-artifacts-*]
//
// How it works:
//   1. Run the shell script on the terminal normally:
//        ./ocp-upgrade-healthcheck-v6.sh 2>&1 | tee /tmp/ocp-run.log
//   2. The server reads /tmp/ocp-run.log + artifact dir and serves the dashboard
//   3. Browser connects and sees the output streamed in real-time via SSE
// =============================================================================

'use strict';

const express  = require('express');
const path     = require('path');
const fs       = require('fs');
const os       = require('os');
const { spawn, execSync } = require('child_process');

// ── CLI args ─────────────────────────────────────────────────────────────────
const args   = process.argv.slice(2);
const getArg = (flag, def) => {
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : def;
};

const PORT        = parseInt(getArg('--port', process.env.PORT || '8080'), 10);
const SCRIPT_PATH = path.resolve(
  getArg('--script', process.env.SCRIPT_PATH ||
    path.join(__dirname, 'ocp-upgrade-healthcheck-v6.sh'))
);
const ARTIFACT_BASE = getArg('--artifacts', process.env.ARTIFACT_BASE || '/tmp');
const LOG_FILE    = path.join(ARTIFACT_BASE, 'ocp-upgrade-live.log');

// ── Run state ─────────────────────────────────────────────────────────────────
let state = {
  running:     false,
  pid:         null,
  startTime:   null,
  exitCode:    null,
  lines:       [],        // { ts, raw, html } — full history, replayed on SSE connect
  artifactDir: null,
};

let sseClients  = [];
let activeProc  = null;

// ── ANSI → HTML ───────────────────────────────────────────────────────────────
// Handles: 0m reset, 1m bold, 31-36, 97, 38;5;208
const ANSI_MAP = {
  '0':        null,           // reset — close all open spans
  '1':        'b',
  '22':       null,
  '31':       'r',
  '32':       'g',
  '33':       'y',
  '34':       'bl',
  '35':       'm',
  '36':       'c',
  '97':       'w',
  '38;5;208': 'o',
};

function ansiToHtml(raw) {
  if (!raw) return '';
  let out = '';
  let openClasses = [];
  let i = 0;

  while (i < raw.length) {
    // Detect ESC[
    if (raw.charCodeAt(i) === 0x1b && raw[i + 1] === '[') {
      const mIdx = raw.indexOf('m', i + 2);
      if (mIdx !== -1) {
        const code = raw.substring(i + 2, mIdx);
        if (code === '0' || code === '22') {
          // close all open spans
          out += '</span>'.repeat(openClasses.length);
          openClasses = [];
        } else {
          const cls = ANSI_MAP[code];
          if (cls) {
            out += `<span class="${cls}">`;
            openClasses.push(cls);
          }
        }
        i = mIdx + 1;
        continue;
      }
    }
    const ch = raw[i];
    if      (ch === '<') out += '&lt;';
    else if (ch === '>') out += '&gt;';
    else if (ch === '&') out += '&amp;';
    else                  out += ch;
    i++;
  }
  // close any dangling spans
  out += '</span>'.repeat(openClasses.length);
  return out;
}

// ── SSE helpers ───────────────────────────────────────────────────────────────
function sse(res, event, data) {
  try {
    res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  } catch (_) { /* client gone */ }
}

function broadcast(event, data) {
  sseClients = sseClients.filter(res => {
    try { res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); return true; }
    catch (_) { return false; }
  });
}

// ── Process a raw output chunk into lines ─────────────────────────────────────
let lineBuf = '';   // handle partial lines across chunks

function processChunk(chunk) {
  lineBuf += chunk.toString();
  const parts = lineBuf.split('\n');
  lineBuf = parts.pop();           // last partial line stays in buffer
  parts.forEach(raw => {
    // Strip carriage returns
    raw = raw.replace(/\r/g, '');
    const html  = ansiToHtml(raw);
    const entry = { ts: Date.now(), raw, html };
    state.lines.push(entry);
    broadcast('line', entry);
  });
}

// ── Run script ────────────────────────────────────────────────────────────────
function runScript(triggerRes) {
  if (state.running) {
    if (triggerRes) triggerRes.status(409).json({ error: 'Already running' });
    return;
  }

  if (!fs.existsSync(SCRIPT_PATH)) {
    const msg = `Script not found at: ${SCRIPT_PATH}`;
    if (triggerRes) triggerRes.status(404).json({ error: msg });
    return;
  }

  const artifactDir = path.join(
    ARTIFACT_BASE,
    `ocp-upgrade-artifacts-${new Date().toISOString().slice(0, 19).replace(/[T:]/g, '-')}`
  );

  // Reset
  lineBuf = '';
  state = {
    running:    true,
    pid:        null,
    startTime:  new Date().toISOString(),
    exitCode:   null,
    lines:      [],
    artifactDir,
  };

  // Respond immediately before spawning so browser can connect SSE
  if (triggerRes) triggerRes.json({ ok: true, artifactDir });

  // Small delay so browser SSE connection is established before first line arrives
  setTimeout(() => _spawnScript(artifactDir), 400);
}

function _spawnScript(artifactDir) {
  broadcast('start', { startTime: state.startTime, artifactDir });

  const env = {
    ...process.env,
    ARTIFACT_DIR: artifactDir,
    TERM:         'xterm-256color',
    COLORTERM:    'truecolor',
    // Force bash color detection even without a TTY
    CLICOLOR_FORCE: '1',
  };

  // Use script(1) on Linux/Mac to fake a TTY so ANSI colors are emitted
  // Falls back to plain bash if script command not available
  let cmd, cmdArgs;
  try {
    execSync('which script', { stdio: 'ignore' });
    const platform = os.platform();
    if (platform === 'darwin') {
      // macOS: script -q /dev/null bash scriptpath
      cmd     = 'script';
      cmdArgs = ['-q', '/dev/null', 'bash', SCRIPT_PATH];
    } else {
      // Linux: script -q -c "bash scriptpath" /dev/null
      cmd     = 'script';
      cmdArgs = ['-q', '-c', `bash "${SCRIPT_PATH}"`, '/dev/null'];
    }
  } catch (_) {
    cmd     = 'bash';
    cmdArgs = [SCRIPT_PATH];
  }

  activeProc = spawn(cmd, cmdArgs, { env, shell: false });
  state.pid  = activeProc.pid;

  activeProc.stdout.on('data', processChunk);
  activeProc.stderr.on('data', processChunk);

  activeProc.on('close', code => {
    // Flush any remaining buffer
    if (lineBuf.trim()) {
      const raw  = lineBuf.replace(/\r/g, '');
      const html = ansiToHtml(raw);
      state.lines.push({ ts: Date.now(), raw, html });
      broadcast('line', { ts: Date.now(), raw, html });
      lineBuf = '';
    }

    state.running  = false;
    state.exitCode = code;
    activeProc     = null;

    // Gather artifacts
    const artifacts = [];
    if (fs.existsSync(state.artifactDir)) {
      fs.readdirSync(state.artifactDir).forEach(f => {
        const fp = path.join(state.artifactDir, f);
        artifacts.push({ name: f, size: fs.statSync(fp).size });
      });
    }

    broadcast('done', { exitCode: code, artifacts });
  });

  activeProc.on('error', err => {
    state.running = false;
    const raw  = `ERROR: ${err.message}`;
    const html = `<span class="r">ERROR: ${err.message}</span>`;
    state.lines.push({ ts: Date.now(), raw, html });
    broadcast('line', { ts: Date.now(), raw, html });
    broadcast('done', { exitCode: 1, artifacts: [] });
  });
}

// ── Express ───────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Status
app.get('/api/status', (_req, res) => {
  res.json({
    running:      state.running,
    pid:          state.pid,
    startTime:    state.startTime,
    exitCode:     state.exitCode,
    lineCount:    state.lines.length,
    scriptPath:   SCRIPT_PATH,
    scriptExists: fs.existsSync(SCRIPT_PATH),
    artifactDir:  state.artifactDir,
    hostname:     os.hostname(),
    platform:     os.platform(),
  });
});

// Run
app.post('/api/run', (req, res) => runScript(res));

// Kill
app.post('/api/kill', (_req, res) => {
  if (!state.running || !activeProc)
    return res.status(400).json({ error: 'Nothing running' });
  activeProc.kill('SIGTERM');
  res.json({ ok: true });
});

// Buffered lines — used by browser on page load/reload to catch up
app.get('/api/lines', (_req, res) => {
  res.json({
    running:     state.running,
    exitCode:    state.exitCode,
    startTime:   state.startTime,
    lines:       state.lines,
    artifactDir: state.artifactDir,
  });
});

// Artifacts list
app.get('/api/artifacts', (_req, res) => {
  const dir = state.artifactDir;
  if (!dir || !fs.existsSync(dir)) return res.json({ files: [] });
  const files = fs.readdirSync(dir).map(f => {
    const fp = path.join(dir, f);
    return { name: f, size: fs.statSync(fp).size };
  });
  res.json({ dir, files });
});

// Artifact download
app.get('/api/artifacts/:name', (req, res) => {
  const dir = state.artifactDir;
  if (!dir) return res.status(404).json({ error: 'No artifacts' });
  const fp = path.join(dir, path.basename(req.params.name));
  if (!fp.startsWith(dir) || !fs.existsSync(fp))
    return res.status(404).json({ error: 'Not found' });
  res.download(fp);
});

// SSE — on connect, replay all buffered lines first, then stream new ones
app.get('/api/stream', (req, res) => {
  res.setHeader('Content-Type',       'text/event-stream');
  res.setHeader('Cache-Control',      'no-cache');
  res.setHeader('Connection',         'keep-alive');
  res.setHeader('X-Accel-Buffering',  'no');
  res.flushHeaders();

  // Replay buffered lines so page-reload works
  state.lines.forEach(entry => sse(res, 'line', entry));

  // If already done, send done event
  if (!state.running && state.exitCode !== null) {
    sse(res, 'done', { exitCode: state.exitCode, artifacts: [] });
    // Still keep connection alive for artifacts fetch
  }

  // If currently running, send start event
  if (state.running) {
    sse(res, 'start', { startTime: state.startTime, artifactDir: state.artifactDir });
  }

  const ka = setInterval(() => {
    try { res.write(': ka\n\n'); } catch (_) { clearInterval(ka); }
  }, 20000);

  sseClients.push(res);
  req.on('close', () => {
    clearInterval(ka);
    sseClients = sseClients.filter(r => r !== res);
  });
});

// ── Boot ──────────────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  const line = '─'.repeat(60);
  console.log(`\n${line}`);
  console.log(' OCP Upgrade Health Check — Web Dashboard v2');
  console.log(line);
  console.log(` Port     : ${PORT}`);
  console.log(` Script   : ${SCRIPT_PATH}`);
  console.log(` Artifacts: ${ARTIFACT_BASE}`);
  console.log(` Hostname : ${os.hostname()}`);
  console.log(line);
  if (!fs.existsSync(SCRIPT_PATH)) {
    console.warn(` WARNING: script not found at ${SCRIPT_PATH}`);
  } else {
    console.log(` Script found. Open http://localhost:${PORT}`);
  }
  console.log(`${line}\n`);
});
