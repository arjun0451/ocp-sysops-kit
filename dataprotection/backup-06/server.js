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

// Ensure data directory exists
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

const LOG_FILE = path.join(DATA_DIR, `log-${POD_NAME}.txt`);
const COUNTER_FILE = path.join(DATA_DIR, `counter-${POD_NAME}.txt`);

// Initialize counter
if (!fs.existsSync(COUNTER_FILE)) fs.writeFileSync(COUNTER_FILE, "0");

// Background write every 3 seconds
setInterval(() => {
    let counter = parseInt(fs.readFileSync(COUNTER_FILE, 'utf-8'));
    counter++;
    const logEntry = `Pod: ${POD_NAME} | Write #${counter} | ${new Date().toISOString()}\n`;
    fs.appendFileSync(LOG_FILE, logEntry);
    fs.writeFileSync(COUNTER_FILE, counter.toString());
}, 3000);

// SHA256 helper
function hash(file) {
    if (!fs.existsSync(file)) return "N/A";
    return crypto.createHash('sha256')
        .update(fs.readFileSync(file))
        .digest('hex');
}

// Disk usage helper
function df(dir) {
    try { return execSync(`df -h ${dir}`).toString(); } 
    catch { return "Unavailable"; }
}

app.get('/', (req, res) => {

    const files = fs.readdirSync(DATA_DIR);
    const counters = files.filter(f => f.startsWith("counter-"));
    const logs = files.filter(f => f.startsWith("log-"));

    const podData = counters.map(file => {
        const pod = file.replace("counter-", "").replace(".txt", "");
        const counter = fs.readFileSync(path.join(DATA_DIR, file), 'utf-8');
        const logFile = logs.find(l => l.includes(pod));
        const logContent = logFile ?
            fs.readFileSync(path.join(DATA_DIR, logFile), 'utf-8')
                .split("\n")
                .slice(-5)
                .join("\n")
            : "No logs";

        return {
            pod,
            counter,
            hash: hash(path.join(DATA_DIR, logFile || "")),
            logs: logContent
        };
    });

    let html = `
    <html>
    <head>
    <meta http-equiv="refresh" content="5">
    <style>
        body {
            font-family: Arial, sans-serif;
            background:#f4f6f9;
            margin:0;
        }

        header {
            background: linear-gradient(90deg,#0066cc,#00cc99);
            color:white;
            padding:20px;
            text-align:center;
        }

        .container {
            padding:20px;
        }

        .disk {
            background:#fff3cd;
            padding:15px;
            border-radius:8px;
            margin-bottom:20px;
        }

        .grid {
            display:flex;
            gap:20px;
            flex-wrap:wrap;
        }

        .card {
            background:white;
            border-radius:10px;
            box-shadow:0 4px 12px rgba(0,0,0,0.1);
            padding:15px;
            width:320px;
            display:flex;
            flex-direction:column;
        }

        .pod {
            font-weight:bold;
            color:#0066cc;
            margin-bottom:5px;
        }

        .counter {
            font-size:18px;
            color:#28a745;
            margin-bottom:10px;
        }

        .hash-box {
            font-family: monospace;
            font-size:11px;
            background:#eef3f8;
            padding:8px;
            border-radius:6px;
            word-break: break-all;
            overflow-wrap: anywhere;
            margin-bottom:10px;
        }

        .log-box {
            font-family: monospace;
            font-size:11px;
            background:#111;
            color:#00ff00;
            padding:10px;
            border-radius:6px;
            height:130px;
            overflow-y:auto;
            white-space: pre-wrap;
            word-break: break-word;
        }

        strong {
            margin-top:8px;
        }
    </style>
    </head>
    <body>

    <header>
        <h1>${BANNER}</h1>
        <p>🕒 ${new Date().toUTCString()}</p>
    </header>

    <div class="container">

        <div class="disk">
            <h3>Filesystem Usage</h3>
            <pre>${df(DATA_DIR)}</pre>
        </div>

        <div class="grid">`;

    podData.forEach(p => {
        html += `
        <div class="card">
            <div class="pod">📦 ${p.pod}</div>
            <div class="counter">Writes: ${p.counter}</div>

            <strong>SHA256</strong>
            <div class="hash-box">${p.hash}</div>

            <strong>Recent Logs</strong>
            <div class="log-box">${p.logs}</div>
        </div>`;
    });

    html += `
        </div>
    </div>
    </body>
    </html>`;

    res.send(html);
});

app.listen(PORT, () => console.log("BCK-07 NFS Stateful App running..."));
