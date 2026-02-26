const express = require('express');
const app = express();
const fs = require('fs');

const PORT = 8080;

function getBanner() {
    try {
        return fs.readFileSync('/config/banner.txt', 'utf8');
    } catch (err) {
        return "Welcome to OpenShift";
    }
}

app.get('/', (req, res) => {
    const now = new Date();

    const response = `
    <html>
        <head>
            <title>OpenShift Backup Test</title>
            <meta http-equiv="refresh" content="1">
        </head>
        <body style="font-family: Arial; text-align:center;">
            <h1>${getBanner()}</h1>
            <h2>Welcome to OpenShift</h2>
            <p><b>UTC Time:</b> ${now.toUTCString()}</p>
            <p><b>Epoch Time:</b> ${Date.now()}</p>
            <p><b>Singapore Time:</b> ${now.toLocaleString("en-SG", { timeZone: "Asia/Singapore" })}</p>
        </body>
    </html>
    `;

    res.send(response);
});

app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});
