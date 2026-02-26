const express = require('express');
const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const os = require('os');
const { execSync } = require('child_process');

const app = express();
const PORT = 8080;
const DATA_DIR = "/data";
const POD_NAME = process.env.HOSTNAME || os.hostname();
const BANNER = process.env.BANNER || "Stateful Backup Validation";

if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

const LOG_FILE     = path.join(DATA_DIR, `log-${POD_NAME}.txt`);
const COUNTER_FILE = path.join(DATA_DIR, `counter-${POD_NAME}.txt`);

if (!fs.existsSync(COUNTER_FILE)) fs.writeFileSync(COUNTER_FILE, "0");

// ── Write every 3 seconds ───────────────────────────────────────────────────
setInterval(() => {
  let counter = parseInt(fs.readFileSync(COUNTER_FILE, 'utf-8'));
  counter++;
  const logEntry = `Pod: ${POD_NAME} | Write #${counter} | ${new Date().toISOString()}\n`;
  fs.appendFileSync(LOG_FILE, logEntry);
  fs.writeFileSync(COUNTER_FILE, counter.toString());
}, 3000);

// ── Helpers ─────────────────────────────────────────────────────────────────
function hash(file) {
  if (!fs.existsSync(file)) return "N/A";
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function df(dir) {
  try { return execSync(`df -h ${dir}`).toString().trim(); }
  catch { return "Unavailable"; }
}

function parseDf(dir) {
  try {
    const lines = execSync(`df -h ${dir}`).toString().trim().split('\n');
    const parts = lines[1].split(/\s+/);
    return { filesystem: parts[0], size: parts[1], used: parts[2], avail: parts[3], usePct: parts[4], mount: parts[5] };
  } catch { return { filesystem: 'N/A', size: 'N/A', used: 'N/A', avail: 'N/A', usePct: '0%', mount: dir }; }
}

function totalWrites(counters, dataDir) {
  return counters.reduce((sum, f) => {
    const val = parseInt(fs.readFileSync(path.join(dataDir, f), 'utf-8')) || 0;
    return sum + val;
  }, 0);
}

// ── Sparkline bars (last N writes normalized to bar heights) ─────────────────
function sparkBars(count, bars = 10) {
  // Simulate last-N activity heights from counter (deterministic per pod)
  const out = [];
  for (let i = 0; i < bars - 1; i++) {
    const h = 40 + Math.round(((count * 7 + i * 13) % 55));
    out.push(h);
  }
  out.push(100); // latest bar always full
  return out;
}

// ── Timeline cells (20 slots, last 60s at 3s intervals) ──────────────────────
function timelineCells(counter, slots = 20) {
  // Cells are all "active" except the very last 2-4 which are "recent"
  const recentCount = 2 + (counter % 3);
  return Array.from({ length: slots }, (_, i) =>
    i >= slots - recentCount ? 'recent' : 'active'
  );
}

// ── Route ────────────────────────────────────────────────────────────────────
app.get('/', (req, res) => {
  const files    = fs.readdirSync(DATA_DIR);
  const counters = files.filter(f => f.startsWith("counter-"));
  const logs     = files.filter(f => f.startsWith("log-"));
  const disk     = parseDf(DATA_DIR);
  const diskPct  = parseInt(disk.usePct) || 0;
  const now      = new Date();

  const podData = counters.map(file => {
    const pod     = file.replace("counter-", "").replace(".txt", "");
    const counter = parseInt(fs.readFileSync(path.join(DATA_DIR, file), 'utf-8')) || 0;
    const logFile = logs.find(l => l.includes(pod));
    const logPath = path.join(DATA_DIR, logFile || "");
    const logLines = logFile
      ? fs.readFileSync(logPath, 'utf-8').split("\n").filter(Boolean).slice(-5)
      : [];
    return {
      pod,
      counter,
      hash: hash(logPath),
      logLines,
      sparkBars: sparkBars(counter),
      timelineCells: timelineCells(counter),
    };
  });

  const total = totalWrites(counters, DATA_DIR);

  // ── Pod cards HTML ────────────────────────────────────────────────────────
  const podCardsHtml = podData.map(p => {
    const bars = p.sparkBars.map((h, i) =>
      `<div class="bar-segment" style="height:${h}%;${i === p.sparkBars.length - 1 ? 'background:var(--teal);' : ''}"></div>`
    ).join('');

    const logRows = p.logLines.map((line, i) => {
      const m = line.match(/Pod: (.+) \| Write #(\d+) \| (.+)/);
      if (!m) return `<div class="log-line" style="color:var(--text-muted)">${line}</div>`;
      const isLast = i === p.logLines.length - 1;
      return `<div class="log-line"${isLast ? ' style="color:var(--teal)"' : ''}>
        <span class="log-pod">${m[1].replace('Pod: ','').split('-').pop()}</span>
        <span class="log-num">#${m[2]}</span>
        <span class="log-time">${m[3].replace('T',' ').split('.')[0]}Z</span>
        ${isLast ? '<span style="color:var(--teal-dim)"> ← latest</span>' : ''}
      </div>`;
    }).join('');

    const tlCells = p.timelineCells.map(cls =>
      `<div class="tl-cell ${cls}"></div>`
    ).join('');

    return `
    <div class="pod-card">
      <div class="pod-head">
        <div class="pod-name">${p.pod}</div>
        <div class="pod-status">RUNNING</div>
      </div>
      <div class="pod-metrics">
        <div class="metric">
          <div class="metric-label">Writes</div>
          <div class="metric-value">${p.counter}</div>
        </div>
        <div class="metric">
          <div class="metric-label">Last Write</div>
          <div class="metric-value" style="font-size:12px;color:var(--blue)">~3s ago</div>
        </div>
      </div>
      <div class="activity-bar">${bars}</div>
      <div class="pod-hash">
        <div class="hash-label">SHA-256</div>
        <div class="hash-value">${p.hash}</div>
      </div>
      <div class="log-terminal">
        <div class="terminal-titlebar">
          <div class="dot dot-r"></div><div class="dot dot-y"></div><div class="dot dot-g"></div>
          <div class="terminal-label">log-${p.pod}.txt</div>
        </div>
        <div class="terminal-body">${logRows || '<div style="color:var(--text-muted)">No logs yet</div>'}</div>
      </div>
    </div>`;
  }).join('');

  // ── Timeline rows HTML ────────────────────────────────────────────────────
  const timelineRowsHtml = podData.map(p => `
    <div style="display:grid;grid-template-columns:80px repeat(20,1fr);gap:3px;margin-bottom:3px;align-items:center;">
      <div class="tl-pod-label">${p.pod.split('-').slice(-2).join('-')}</div>
      ${p.timelineCells.map(cls => `<div class="tl-cell ${cls}"></div>`).join('')}
    </div>`
  ).join('');

  // ── Full HTML ─────────────────────────────────────────────────────────────
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="5">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>BCK-07 | ${BANNER}</title>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@300;400;500;600&family=IBM+Plex+Sans:wght@300;400;500;600;700&display=swap" rel="stylesheet">
<style>
  :root {
    --bg-base:      #0a0e17;
    --bg-surface:   #0f1420;
    --bg-card:      #131929;
    --bg-elevated:  #1a2235;
    --border:       #1e2d45;
    --border-glow:  #1e4080;
    --teal:         #00e5a0;
    --teal-dim:     #00996a;
    --blue:         #3b8bff;
    --blue-dim:     #1a4a9e;
    --amber:        #f5a623;
    --red:          #ff4d6a;
    --green:        #39d353;
    --text-primary:   #e8edf5;
    --text-secondary: #7a8ba8;
    --text-muted:     #3d5070;
    --font-mono: 'IBM Plex Mono', monospace;
    --font-sans: 'IBM Plex Sans', sans-serif;
    --radius: 8px;
  }
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: var(--font-sans);
    background: var(--bg-base);
    color: var(--text-primary);
    min-height: 100vh;
  }
  body::before {
    content: '';
    position: fixed; inset: 0;
    background-image:
      linear-gradient(rgba(59,139,255,0.03) 1px, transparent 1px),
      linear-gradient(90deg, rgba(59,139,255,0.03) 1px, transparent 1px);
    background-size: 40px 40px;
    pointer-events: none; z-index: 0;
  }
  /* TOP BAR */
  .topbar {
    position: relative; z-index: 10;
    display: flex; align-items: center; justify-content: space-between;
    padding: 0 28px; height: 56px;
    background: var(--bg-surface);
    border-bottom: 1px solid var(--border);
  }
  .topbar-left { display: flex; align-items: center; gap: 12px; }
  .logo-badge {
    font-family: var(--font-mono); font-size: 11px; font-weight: 600;
    letter-spacing: 2px; color: var(--bg-base); background: var(--teal);
    padding: 3px 8px; border-radius: 4px;
  }
  .topbar-title { font-size: 14px; font-weight: 600; }
  .topbar-right { display: flex; align-items: center; gap: 20px; }
  .live-pill {
    display: flex; align-items: center; gap: 7px;
    font-family: var(--font-mono); font-size: 11px;
    color: var(--teal); letter-spacing: 1px;
  }
  .pulse-dot {
    width: 7px; height: 7px; border-radius: 50%; background: var(--teal);
    animation: pulse 2s ease-in-out infinite;
  }
  @keyframes pulse {
    0%,100% { opacity:1; transform:scale(1); box-shadow:0 0 0 0 rgba(0,229,160,.5); }
    50%      { opacity:.7; transform:scale(.9); box-shadow:0 0 0 5px rgba(0,229,160,0); }
  }
  .clock { font-family: var(--font-mono); font-size: 12px; color: var(--text-secondary); }
  /* MAIN */
  .main { position: relative; z-index: 1; padding: 28px; max-width: 1400px; margin: 0 auto; }
  /* STAT ROW */
  .stat-row {
    display: grid; grid-template-columns: repeat(4,1fr);
    gap: 16px; margin-bottom: 24px;
    animation: fadeUp 0.4s ease both;
  }
  @keyframes fadeUp {
    from { opacity:0; transform:translateY(12px); }
    to   { opacity:1; transform:translateY(0); }
  }
  .stat-card {
    background: var(--bg-card); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 16px 20px;
    display: flex; flex-direction: column; gap: 6px;
    transition: border-color .2s;
  }
  .stat-card:hover { border-color: var(--border-glow); }
  .stat-label {
    font-size: 10px; font-weight: 500; letter-spacing: 1.5px;
    color: var(--text-muted); text-transform: uppercase;
    font-family: var(--font-mono);
  }
  .stat-value { font-size: 26px; font-weight: 700; line-height: 1; font-family: var(--font-mono); }
  .stat-value.teal  { color: var(--teal); }
  .stat-value.blue  { color: var(--blue); }
  .stat-value.amber { color: var(--amber); }
  .stat-value.green { color: var(--green); }
  .stat-sub { font-size: 11px; color: var(--text-secondary); font-family: var(--font-mono); }
  /* LAYOUT */
  .layout-row {
    display: grid; grid-template-columns: 1fr 340px;
    gap: 20px; margin-bottom: 24px;
    animation: fadeUp 0.4s ease 0.1s both;
  }
  .section-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px; }
  .section-title {
    font-size: 11px; font-weight: 600; letter-spacing: 2px;
    text-transform: uppercase; color: var(--text-secondary);
    font-family: var(--font-mono);
    display: flex; align-items: center; gap: 8px;
  }
  .section-title::before {
    content: ''; display: inline-block; width: 3px; height: 13px;
    background: var(--teal); border-radius: 2px;
  }
  /* POD PANEL */
  .pods-panel {
    background: var(--bg-card); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 20px;
  }
  .pod-grid { display: grid; grid-template-columns: repeat(auto-fill,minmax(260px,1fr)); gap: 14px; }
  .pod-card {
    background: var(--bg-elevated); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 16px;
    position: relative; overflow: hidden;
    transition: border-color .2s, box-shadow .2s;
  }
  .pod-card::before {
    content: ''; position: absolute; top:0;left:0;right:0; height: 2px;
    background: linear-gradient(90deg,var(--teal),var(--blue));
    opacity: 0; transition: opacity .2s;
  }
  .pod-card:hover { border-color: var(--border-glow); box-shadow: 0 0 20px rgba(59,139,255,.15); }
  .pod-card:hover::before { opacity: 1; }
  .pod-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px; }
  .pod-name {
    font-family: var(--font-mono); font-size: 12px; font-weight: 600;
    color: var(--blue); display: flex; align-items: center; gap: 6px;
  }
  .pod-name::before { content: '▸'; color: var(--teal); font-size: 10px; }
  .pod-status {
    font-family: var(--font-mono); font-size: 9px; font-weight: 600;
    letter-spacing: 1.5px; padding: 2px 7px; border-radius: 3px;
    background: rgba(0,229,160,.1); color: var(--teal);
    border: 1px solid rgba(0,229,160,.2);
  }
  .pod-metrics { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 14px; }
  .metric {
    background: var(--bg-surface); border-radius: 6px; padding: 10px;
    border: 1px solid var(--border);
  }
  .metric-label {
    font-size: 9px; letter-spacing: 1px; color: var(--text-muted);
    text-transform: uppercase; font-family: var(--font-mono); margin-bottom: 4px;
  }
  .metric-value { font-family: var(--font-mono); font-size: 18px; font-weight: 600; color: var(--teal); }
  .activity-bar { display: flex; gap: 3px; margin-bottom: 14px; align-items: flex-end; height: 28px; }
  .bar-segment { flex: 1; border-radius: 2px; background: var(--border-glow); min-height: 4px; }
  .pod-hash {
    background: var(--bg-surface); border-radius: 6px; padding: 8px 10px;
    border: 1px solid var(--border); margin-bottom: 12px;
  }
  .hash-label {
    font-size: 9px; letter-spacing: 1px; color: var(--text-muted);
    text-transform: uppercase; font-family: var(--font-mono); margin-bottom: 4px;
    display: flex; align-items: center; gap: 5px;
  }
  .hash-label::before { content: '⬡'; color: var(--amber); font-size: 9px; }
  .hash-value {
    font-family: var(--font-mono); font-size: 9px; color: var(--amber);
    word-break: break-all; line-height: 1.6; letter-spacing: .5px;
  }
  .log-terminal { background: var(--bg-base); border-radius: 6px; border: 1px solid var(--border); overflow: hidden; }
  .terminal-titlebar {
    display: flex; align-items: center; padding: 6px 10px;
    background: var(--bg-surface); border-bottom: 1px solid var(--border); gap: 6px;
  }
  .dot { width: 8px; height: 8px; border-radius: 50%; }
  .dot-r { background: #ff5f57; } .dot-y { background: #febc2e; } .dot-g { background: #28c840; }
  .terminal-label { font-family: var(--font-mono); font-size: 9px; color: var(--text-muted); margin-left: 4px; letter-spacing: 1px; }
  .terminal-body { padding: 10px; font-family: var(--font-mono); font-size: 10px; line-height: 1.7; color: #8fafd4; }
  .log-line { display: flex; gap: 8px; flex-wrap: wrap; }
  .log-pod { color: var(--blue); flex-shrink: 0; }
  .log-num { color: var(--teal); flex-shrink: 0; }
  .log-time { color: var(--text-muted); flex-shrink: 0; }
  /* DISK PANEL */
  .disk-panel {
    background: var(--bg-card); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 20px;
    display: flex; flex-direction: column; gap: 16px;
  }
  .disk-gauge-wrap { display: flex; flex-direction: column; gap: 10px; }
  .disk-info { display: flex; justify-content: space-between; align-items: baseline; }
  .disk-mount { font-family: var(--font-mono); font-size: 11px; color: var(--blue); }
  .disk-pct { font-family: var(--font-mono); font-size: 20px; font-weight: 700; color: var(--teal); }
  .gauge-track { height: 6px; background: var(--border); border-radius: 3px; overflow: hidden; }
  .gauge-fill { height: 100%; border-radius: 3px; background: linear-gradient(90deg,var(--teal),var(--blue)); }
  .disk-stats { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; }
  .disk-stat {
    background: var(--bg-elevated); border: 1px solid var(--border);
    border-radius: 6px; padding: 10px; text-align: center;
  }
  .disk-stat-label {
    font-size: 9px; letter-spacing: 1px; color: var(--text-muted);
    text-transform: uppercase; font-family: var(--font-mono); margin-bottom: 4px;
  }
  .disk-stat-value { font-family: var(--font-mono); font-size: 14px; font-weight: 600; color: var(--text-primary); }
  .disk-raw {
    background: var(--bg-base); border: 1px solid var(--border);
    border-radius: 6px; padding: 10px;
    font-family: var(--font-mono); font-size: 9.5px;
    color: var(--text-secondary); line-height: 1.7; white-space: pre; overflow-x: auto;
  }
  /* TIMELINE */
  .timeline-panel {
    background: var(--bg-card); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 20px;
    animation: fadeUp 0.4s ease 0.2s both;
  }
  .tl-pod-label { font-family: var(--font-mono); font-size: 9px; color: var(--text-secondary); text-align: right; padding-right: 10px; }
  .tl-cell { height: 22px; border-radius: 3px; background: var(--border); }
  .tl-cell.active { background: linear-gradient(135deg,#00996a,#1a4a9e); animation: shimmer 2s ease-in-out infinite; }
  .tl-cell.recent { background: rgba(0,229,160,.3); }
  @keyframes shimmer { 0%,100%{opacity:.8} 50%{opacity:1} }
  .tl-time-label { font-family: var(--font-mono); font-size: 8px; color: var(--text-muted); text-align: center; }
  /* FOOTER */
  .footer {
    position: relative; z-index: 1;
    border-top: 1px solid var(--border); padding: 14px 28px;
    display: flex; align-items: center; justify-content: space-between;
    background: var(--bg-surface);
  }
  .footer-left { font-family: var(--font-mono); font-size: 10px; color: var(--text-muted); display: flex; gap: 20px; }
  .footer-right { font-family: var(--font-mono); font-size: 10px; color: var(--text-muted); }
  .footer-item span { color: var(--text-secondary); }
  @media (max-width: 900px) {
    .stat-row { grid-template-columns: repeat(2,1fr); }
    .layout-row { grid-template-columns: 1fr; }
  }
</style>
</head>
<body>

<header class="topbar">
  <div class="topbar-left">
    <span class="logo-badge">BCK-07</span>
    <span class="topbar-title">${BANNER}</span>
  </div>
  <div class="topbar-right">
    <div class="live-pill"><span class="pulse-dot"></span>LIVE · AUTO-REFRESH 5s</div>
    <div class="clock">${now.toUTCString()}</div>
  </div>
</header>

<main class="main">

  <div class="stat-row">
    <div class="stat-card">
      <div class="stat-label">Active Pods</div>
      <div class="stat-value teal">${podData.length}</div>
      <div class="stat-sub">${podData.map(p=>p.pod).join(', ') || 'none'}</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Total Writes</div>
      <div class="stat-value blue">${total}</div>
      <div class="stat-sub">across all pods</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Write Rate</div>
      <div class="stat-value amber">1/3s</div>
      <div class="stat-sub">per pod interval</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Disk Used</div>
      <div class="stat-value green">${disk.usePct}</div>
      <div class="stat-sub">${disk.used} of ${disk.size}</div>
    </div>
  </div>

  <div class="layout-row">
    <div class="pods-panel">
      <div class="section-header">
        <div class="section-title">Pod Status</div>
        <div style="font-family:var(--font-mono);font-size:10px;color:var(--text-muted)">NFS · ${DATA_DIR}</div>
      </div>
      <div class="pod-grid">${podCardsHtml}</div>
    </div>

    <div class="disk-panel">
      <div class="section-header">
        <div class="section-title">Filesystem</div>
      </div>
      <div class="disk-gauge-wrap">
        <div class="disk-info">
          <div class="disk-mount">${disk.filesystem} → ${disk.mount}</div>
          <div class="disk-pct">${disk.usePct}</div>
        </div>
        <div class="gauge-track">
          <div class="gauge-fill" style="width:${diskPct}%"></div>
        </div>
      </div>
      <div class="disk-stats">
        <div class="disk-stat">
          <div class="disk-stat-label">Total</div>
          <div class="disk-stat-value">${disk.size}</div>
        </div>
        <div class="disk-stat">
          <div class="disk-stat-label">Used</div>
          <div class="disk-stat-value" style="color:var(--amber)">${disk.used}</div>
        </div>
        <div class="disk-stat">
          <div class="disk-stat-label">Free</div>
          <div class="disk-stat-value" style="color:var(--teal)">${disk.avail}</div>
        </div>
      </div>
      <div class="disk-raw">${df(DATA_DIR)}</div>
    </div>
  </div>

  <div class="timeline-panel">
    <div class="section-header">
      <div class="section-title">Write Activity Timeline</div>
      <div style="font-family:var(--font-mono);font-size:10px;color:var(--text-muted)">last 60s · 3s intervals</div>
    </div>
    <div style="margin-left:80px;display:grid;grid-template-columns:repeat(20,1fr);gap:3px;margin-bottom:4px;">
      ${['−60s','','','','−45s','','','','−30s','','','','−15s','','','','','','','now']
        .map(l=>`<div class="tl-time-label">${l}</div>`).join('')}
    </div>
    ${timelineRowsHtml}
  </div>

</main>

<footer class="footer">
  <div class="footer-left">
    <div class="footer-item">POD <span>${POD_NAME}</span></div>
    <div class="footer-item">DATA_DIR <span>${DATA_DIR}</span></div>
    <div class="footer-item">PORT <span>${PORT}</span></div>
    <div class="footer-item">NODE <span>${process.version}</span></div>
  </div>
  <div class="footer-right">BCK-07 NFS Stateful App · Express ${require('express/package.json').version}</div>
</footer>

</body>
</html>`;

  res.send(html);
});

app.listen(PORT, () => console.log(`BCK-07 NFS Stateful App running on :${PORT}`));
