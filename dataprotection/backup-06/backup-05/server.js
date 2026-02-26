const express = require('express');
const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const os = require('os');
const { execSync } = require('child_process');

const app = express();
const PORT = 8080;
const DATA_DIR = "/data";
const BANNER = process.env.BANNER || "Stateful Backup Test";

// Ensure data directory exists
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

// Identify pod
const POD_NAME = process.env.HOSTNAME || os.hostname();
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
    return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

// Disk usage helper
function df(dir) {
    try { return execSync(`df -h ${dir}`).toString(); } 
    catch { return "Unavailable"; }
}

// Endpoint
app.get('/', (req, res) => {
    const files = fs.readdirSync(DATA_DIR);
    const counterFiles = files.filter(f => f.startsWith("counter-"));
    const logFiles = files.filter(f => f.startsWith("log-"));

    const podData = counterFiles.map(file => {
        const pod = file.split('-').slice(2).join('-').replace('.txt', '');
        const counterPath = path.join(DATA_DIR, file);
        const logFile = logFiles.find(lf => lf.includes(pod));
        const logPath = logFile ? path.join(DATA_DIR, logFile) : null;
        return {
            pod,
            counter: fs.existsSync(counterPath) ? fs.readFileSync(counterPath, 'utf-8') : "N/A",
            logs: logPath && fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf-8').split("\n").slice(-5).join("\n") : "No logs yet",
            hash: logPath ? hash(logPath) : "N/A"
        };
    });

    let html = `<html><head><meta http-equiv="refresh" content="5"></head><body style="font-family: Arial;">
        <h1 style="text-align:center;">${BANNER}</h1>
        <h2>Overall Filesystem Usage</h2><pre>${df(DATA_DIR)}</pre>
        <div style="display:flex; justify-content:space-around;">`;

    podData.forEach(pod => {
        html += `<div style="width:30%; border:1px solid black; padding:10px;">
            <h3>Pod: ${pod.pod}</h3>
            <p><b>Write Counter:</b> ${pod.counter}</p>
            <p><b>SHA256 (log file):</b><br>${pod.hash}</p>
            <h4>Last 5 Log Entries</h4><pre>${pod.logs}</pre>
        </div>`;
    });

    html += `</div><p style="text-align:center;"><b>UTC Time:</b> ${new Date().toUTCString()}</p></body></html>`;
    res.send(html);
});

app.listen(PORT, () => console.log(`Stateful Test App running on port ${PORT}...`));
