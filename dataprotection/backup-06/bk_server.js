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
const BANNER = process.env.BANNER || "OpenShift Backup Validation";

if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

const LOG_FILE = path.join(DATA_DIR, `log-${POD_NAME}.txt`);
const COUNTER_FILE = path.join(DATA_DIR, `counter-${POD_NAME}.txt`);

if (!fs.existsSync(COUNTER_FILE)) fs.writeFileSync(COUNTER_FILE, "0");

setInterval(() => {
    let counter = parseInt(fs.readFileSync(COUNTER_FILE, 'utf-8'));
    counter++;
    const logEntry = `Pod: ${POD_NAME} | Write #${counter} | ${new Date().toISOString()}\n`;
    fs.appendFileSync(LOG_FILE, logEntry);
    fs.writeFileSync(COUNTER_FILE, counter.toString());
}, 3000);

function sha(file) {
    if (!fs.existsSync(file)) return "N/A";
    return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function diskStats() {
    try {
        const out = execSync(`df -h ${DATA_DIR}`).toString().split("\n")[1];
        const parts = out.split(/\s+/);
        return {
            size: parts[1],
            used: parts[2],
            avail: parts[3],
            percent: parts[4]
        };
    } catch {
        return { size: "N/A", used: "N/A", avail: "N/A", percent: "0%" };
    }
}

app.get('/', (req, res) => {
    const files = fs.readdirSync(DATA_DIR);
    const counters = files.filter(f => f.startsWith("counter-"));
    const logs = files.filter(f => f.startsWith("log-"));

    let totalWrites = 0;
    let podData = [];

    counters.forEach(file => {
        const pod = file.replace("counter-", "").replace(".txt", "");
        const counter = parseInt(fs.readFileSync(path.join(DATA_DIR, file), 'utf-8'));
        totalWrites += counter;

        const logFile = logs.find(l => l.includes(pod));
        const logContent = logFile ?
            fs.readFileSync(path.join(DATA_DIR, logFile), 'utf-8')
            .split("\n").slice(-10) : [];

        podData.push({
            pod,
            counter,
            hash: sha(path.join(DATA_DIR, logFile || "")),
            logs: logContent
        });
    });

    const disk = diskStats();
    const writeRate = (totalWrites / 60).toFixed(2); // approx per minute

    let html = `
<!DOCTYPE html>
<html>
<head>
<meta http-equiv="refresh" content="5">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono&family=IBM+Plex+Sans:wght@400;600&display=swap" rel="stylesheet">
<style>
:root{
    --bg:#0a192f;
    --panel:#112240;
    --accent:#00f5d4;
    --accent2:#1da1f2;
    --text:#ccd6f6;
    --muted:#8892b0;
}
body{
    margin:0;
    font-family:'IBM Plex Sans',sans-serif;
    background:var(--bg);
    color:var(--text);
}
.topbar{
    background:#07101f;
    padding:15px 25px;
    display:flex;
    justify-content:space-between;
    align-items:center;
    border-bottom:2px solid var(--accent);
}
.pulse{
    width:12px;height:12px;border-radius:50%;
    background:var(--accent);
    animation:pulse 1.5s infinite;
}
@keyframes pulse{
    0%{box-shadow:0 0 0 0 rgba(0,245,212,0.7);}
    70%{box-shadow:0 0 0 10px rgba(0,245,212,0);}
    100%{box-shadow:0 0 0 0 rgba(0,245,212,0);}
}
.summary{
    display:grid;
    grid-template-columns:repeat(4,1fr);
    gap:15px;
    padding:20px;
}
.card{
    background:var(--panel);
    padding:15px;
    border-radius:8px;
}
.grid{
    display:flex;
    gap:20px;
    flex-wrap:wrap;
    padding:20px;
}
.podcard{
    background:var(--panel);
    width:320px;
    padding:15px;
    border-radius:8px;
}
.spark span{
    display:inline-block;
    width:5px;
    margin-right:2px;
    background:var(--accent2);
}
.terminal{
    background:black;
    color:#00ff00;
    font-family:'IBM Plex Mono',monospace;
    padding:10px;
    font-size:12px;
    height:120px;
    overflow:auto;
}
.gauge{
    background:#1c2b45;
    border-radius:10px;
    overflow:hidden;
}
.gauge-bar{
    background:linear-gradient(90deg,var(--accent),var(--accent2));
    height:15px;
}
.heatmap{
    display:grid;
    grid-template-columns:repeat(20,10px);
    gap:2px;
}
.heat{
    width:10px;height:10px;
}
</style>
</head>
<body>

<div class="topbar">
    <div><strong>${BANNER}</strong></div>
    <div style="display:flex;align-items:center;gap:10px;">
        <div class="pulse"></div>
        <div>UTC: ${new Date().toUTCString()}</div>
    </div>
</div>

<div class="summary">
    <div class="card"><h3>Pods</h3><p>${podData.length}</p></div>
    <div class="card"><h3>Total Writes</h3><p>${totalWrites}</p></div>
    <div class="card"><h3>Write Rate</h3><p>${writeRate}/min</p></div>
    <div class="card"><h3>Disk Used</h3><p>${disk.percent}</p></div>
</div>

<div style="padding:20px;">
    <h3>Disk Usage</h3>
    <div class="gauge">
        <div class="gauge-bar" style="width:${disk.percent};"></div>
    </div>
    <p>${disk.used} / ${disk.size} (Available: ${disk.avail})</p>
</div>

<div class="grid">`;

    podData.forEach(p => {

        let spark = "";
        for(let i=0;i<20;i++){
            const h = Math.floor(Math.random()*20)+5;
            spark += `<span style="height:${h}px;"></span>`;
        }

        html += `
        <div class="podcard">
            <h4>${p.pod}</h4>
            <p>Writes: ${p.counter}</p>
            <div class="spark">${spark}</div>
            <p><small>SHA256:</small><br><span style="font-size:11px;">${p.hash}</span></p>
            <div class="terminal">${p.logs.join("<br>")}</div>
        </div>`;
    });

    html += `</div>

<div style="padding:20px;">
<h3>Write Activity Heatmap</h3>
<div class="heatmap">`;

    for(let i=0;i<100;i++){
        const intensity = Math.floor(Math.random()*255);
        html += `<div class="heat" style="background:rgb(0,${intensity},${intensity});"></div>`;
    }

    html += `
</div>
</div>

</body>
</html>
`;

    res.send(html);
});

app.listen(PORT, () => console.log("Dark Ops Dashboard running..."));
