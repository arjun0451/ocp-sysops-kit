const express = require('express');
const fs = require('fs');
const crypto = require('crypto');
const { execSync } = require('child_process');
const path = require('path');

const app = express();
const PORT = 8080;
const DATA_DIR = "/data";

const LOG_FILE = path.join(DATA_DIR, "app.log");
const BIG_FILE = path.join(DATA_DIR, "100mb-test.bin");
const COUNTER_FILE = path.join(DATA_DIR, "write-counter.txt");

if (!fs.existsSync(DATA_DIR)) {
    fs.mkdirSync(DATA_DIR, { recursive: true });
}

// Create 100MB file if not exists
if (!fs.existsSync(BIG_FILE)) {
    console.log("Creating 100MB test file...");
    const stream = fs.createWriteStream(BIG_FILE);
    const chunk = Buffer.alloc(1024 * 1024, "A"); // 1MB
    for (let i = 0; i < 100; i++) {
        stream.write(chunk);
    }
    stream.end();
}

// Initialize counter
if (!fs.existsSync(COUNTER_FILE)) {
    fs.writeFileSync(COUNTER_FILE, "0");
}

// Background writer process
setInterval(() => {
    let counter = parseInt(fs.readFileSync(COUNTER_FILE));
    counter++;

    const logEntry = `Write #${counter} at ${new Date().toISOString()}\n`;

    fs.appendFileSync(LOG_FILE, logEntry);
    fs.writeFileSync(COUNTER_FILE, counter.toString());

}, 3000);

// Calculate SHA256
function calculateHash(filePath) {
    if (!fs.existsSync(filePath)) return "File not found";
    const fileBuffer = fs.readFileSync(filePath);
    const hashSum = crypto.createHash('sha256');
    hashSum.update(fileBuffer);
    return hashSum.digest('hex');
}

// Get disk usage
function getDiskUsage() {
    try {
        const output = execSync(`df -h ${DATA_DIR}`).toString();
        return output;
    } catch (err) {
        return "Unable to fetch disk usage";
    }
}

app.get('/', (req, res) => {

    const files = fs.readdirSync(DATA_DIR);
    const stats = fs.statSync(BIG_FILE);
    const counter = fs.readFileSync(COUNTER_FILE);

    const logs = fs.existsSync(LOG_FILE)
        ? fs.readFileSync(LOG_FILE).toString().split("\n").slice(-6).join("\n")
        : "No logs yet";

    res.send(`
    <html>
    <head>
        <meta http-equiv="refresh" content="5">
    </head>
    <body style="font-family: Arial; text-align:center;">
        <h1>🚀 OpenShift Stateful Backup Test - BCK-02</h1>

        <h3>Disk Usage</h3>
        <pre>${getDiskUsage()}</pre>

        <h3>Files in PVC</h3>
        <pre>${files.join("\n")}</pre>

        <p><b>100MB File Size:</b> ${(stats.size / (1024*1024)).toFixed(2)} MB</p>

        <p><b>Write Counter:</b> ${counter}</p>

        <p><b>SHA256 (100MB file):</b><br>${calculateHash(BIG_FILE)}</p>

        <h3>Last 5 Log Entries</h3>
        <pre>${logs}</pre>

        <p><b>UTC Time:</b> ${new Date().toUTCString()}</p>

    </body>
    </html>
    `);
});

app.listen(PORT, () => {
    console.log("Enterprise Stateful Test App running...");
});
