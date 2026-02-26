const express = require('express');
const fs = require('fs');
const crypto = require('crypto');
const { execSync } = require('child_process');
const path = require('path');

const app = express();
const PORT = 8080;

const PVC1 = "/data1";
const PVC2 = "/data2";

const FILE1 = path.join(PVC1, "data-file.bin");
const FILE2 = path.join(PVC2, "log-file.log");

const COUNTER1 = path.join(PVC1, "counter1.txt");
const COUNTER2 = path.join(PVC2, "counter2.txt");

// Ensure directories exist
[PVC1, PVC2].forEach(dir => {
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
});

// Create 50MB file in PVC1 if not exists
if (!fs.existsSync(FILE1)) {
    const stream = fs.createWriteStream(FILE1);
    const chunk = Buffer.alloc(1024 * 1024, "B");
    for (let i = 0; i < 50; i++) stream.write(chunk);
    stream.end();
}

// Initialize counters
if (!fs.existsSync(COUNTER1)) fs.writeFileSync(COUNTER1, "0");
if (!fs.existsSync(COUNTER2)) fs.writeFileSync(COUNTER2, "0");

// Background writers
setInterval(() => {
    let c1 = parseInt(fs.readFileSync(COUNTER1));
    c1++;
    fs.appendFileSync(FILE1, `\nData Write #${c1} ${new Date().toISOString()}`);
    fs.writeFileSync(COUNTER1, c1.toString());
}, 4000);

setInterval(() => {
    let c2 = parseInt(fs.readFileSync(COUNTER2));
    c2++;
    fs.appendFileSync(FILE2, `Log Write #${c2} ${new Date().toISOString()}\n`);
    fs.writeFileSync(COUNTER2, c2.toString());
}, 3000);

// Hash function
function hash(file) {
    if (!fs.existsSync(file)) return "N/A";
    const data = fs.readFileSync(file);
    return crypto.createHash('sha256').update(data).digest('hex');
}

// Disk usage
function df(path) {
    try {
        return execSync(`df -h ${path}`).toString();
    } catch {
        return "Unavailable";
    }
}

app.get('/', (req, res) => {

    const size1 = fs.existsSync(FILE1)
        ? (fs.statSync(FILE1).size / (1024*1024)).toFixed(2)
        : "0";

    const logs2 = fs.existsSync(FILE2)
        ? fs.readFileSync(FILE2).toString().split("\n").slice(-5).join("\n")
        : "No logs";

    res.send(`
    <html>
    <head>
        <meta http-equiv="refresh" content="5">
    </head>
    <body style="font-family: Arial;">

        <h1 style="text-align:center;">🚀 OpenShift Multi-PVC Backup Test - BCK-03</h1>

        <h2>Overall Filesystem Summary</h2>
        <pre>${df("/")}</pre>

        <div style="display:flex; justify-content:space-around;">

            <div style="width:45%; border:1px solid black; padding:10px;">
                <h3>PVC-1 (/data1)</h3>
                <pre>${df(PVC1)}</pre>
                <p><b>File Size:</b> ${size1} MB</p>
                <p><b>Write Counter:</b> ${fs.readFileSync(COUNTER1)}</p>
                <p><b>SHA256:</b><br>${hash(FILE1)}</p>
            </div>

            <div style="width:45%; border:1px solid black; padding:10px;">
                <h3>PVC-2 (/data2)</h3>
                <pre>${df(PVC2)}</pre>
                <p><b>Write Counter:</b> ${fs.readFileSync(COUNTER2)}</p>
                <p><b>SHA256:</b><br>${hash(FILE2)}</p>
                <h4>Last 5 Log Entries</h4>
                <pre>${logs2}</pre>
            </div>

        </div>

        <p style="text-align:center;"><b>UTC Time:</b> ${new Date().toUTCString()}</p>

    </body>
    </html>
    `);
});

app.listen(PORT, () => {
    console.log("Multi-PVC test app running...");
});
