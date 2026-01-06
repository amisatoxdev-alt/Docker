FROM ubuntu:22.04

# --- 1. SETUP ENVIRONMENT ---
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080

# --- 2. INSTALL DEPENDENCIES ---
# Java 21 (Latest), Node.js, Unzip
RUN apt-get update && apt-get install -y \
    curl wget git tar sudo unzip zip \
    openjdk-21-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# --- 3. SETUP APP ---
WORKDIR /app
RUN npm init -y && \
    npm install express socket.io multer fs-extra body-parser express-session adm-zip axios

# Default Settings
RUN echo "eula=true" > eula.txt
RUN echo '{"ram": "1G", "jar": "server.jar"}' > settings.json

# *** FORCE GAME PORT TO 25565 ***
RUN echo "server-port=25565" > server.properties

# --- 4. BACKEND (server.js) ---
RUN cat << 'EOF' > server.js
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const { spawn } = require('child_process');
const fs = require('fs-extra');
const path = require('path');
const session = require('express-session');
const bodyParser = require('body-parser');
const multer = require('multer');
const AdmZip = require('adm-zip');
const axios = require('axios');

const app = express();
const server = http.createServer(app);
const io = new Server(server);
const upload = multer({ dest: 'temp_uploads/' });

const SETTINGS_FILE = 'settings.json';
const USERS_FILE = 'users.json';
let mcProcess = null;
let consoleLog = [];

app.use(express.static('public'));
app.use(bodyParser.json());
app.use(session({ secret: 'railway-secret', resave: false, saveUninitialized: true }));

function getSettings() {
    if (!fs.existsSync(SETTINGS_FILE)) fs.writeJsonSync(SETTINGS_FILE, { ram: "1G", jar: "server.jar" });
    return fs.readJsonSync(SETTINGS_FILE);
}

function saveSettings(data) {
    const current = getSettings();
    fs.writeJsonSync(SETTINGS_FILE, { ...current, ...data });
}

function checkAuth(req, res, next) {
    if (req.session.loggedin) next();
    else res.status(403).json({ error: 'Not logged in' });
}

// --- ROUTES ---

// Auth
app.post('/api/auth', (req, res) => {
    const { username, password } = req.body;
    let users = {};
    if (fs.existsSync(USERS_FILE)) users = fs.readJsonSync(USERS_FILE, { throws: false }) || {};
    
    if (Object.keys(users).length === 0) {
        users[username] = password;
        fs.writeJsonSync(USERS_FILE, users);
        req.session.loggedin = true;
        return res.json({ success: true, msg: 'Admin Created' });
    }
    
    if (users[username] && users[username] === password) {
        req.session.loggedin = true;
        return res.json({ success: true });
    }
    res.json({ success: false, msg: 'Invalid Credentials' });
});

app.get('/api/check-setup', (req, res) => {
    const users = fs.existsSync(USERS_FILE) ? fs.readJsonSync(USERS_FILE, { throws: false }) || {} : {};
    res.json({ setupNeeded: Object.keys(users).length === 0 });
});

// Server Control
app.post('/api/start', checkAuth, (req, res) => {
    if (mcProcess) return res.json({ msg: 'Server already running' });
    
    const settings = getSettings();
    const ram = settings.ram || "1G";
    const jar = settings.jar || "server.jar";
    
    if (!fs.existsSync(jar)) return res.json({ msg: `File '${jar}' not found! Go to Settings and install it.` });

    io.emit('log', `\n>>> STARTING SERVER (RAM: ${ram}, JAR: ${jar})...\n`);
    
    // We pass RAM directly to Java
    mcProcess = spawn('java', [`-Xmx${ram}`, `-Xms${ram}`, '-jar', jar, 'nogui']);
    
    mcProcess.stdout.on('data', d => {
        const line = d.toString();
        consoleLog.push(line);
        if (consoleLog.length > 500) consoleLog.shift();
        io.emit('log', line);
        process.stdout.write(line);
    });
    
    mcProcess.stderr.on('data', d => {
        const line = d.toString();
        io.emit('log', line);
        process.stdout.write(line);
    });
    
    mcProcess.on('close', () => {
        mcProcess = null;
        io.emit('log', '\n>>> SERVER STOPPED <<<\n');
        io.emit('status', 'stopped');
    });
    
    io.emit('status', 'running');
    res.json({ success: true });
});

app.post('/api/stop', checkAuth, (req, res) => {
    if (mcProcess) {
        mcProcess.stdin.write("stop\n");
        res.json({ success: true });
    } else {
        res.json({ msg: 'Server not running' });
    }
});

// Settings
app.get('/api/settings', checkAuth, (req, res) => res.json(getSettings()));
app.post('/api/settings', checkAuth, (req, res) => {
    saveSettings(req.body);
    res.json({ success: true });
});

// Installer
app.post('/api/install', checkAuth, async (req, res) => {
    const { url, type, filename } = req.body;
    const targetDir = type === 'plugin' ? 'plugins' : '.';
    fs.ensureDirSync(targetDir);
    const targetPath = path.join(targetDir, filename);
    
    try {
        io.emit('log', `\n>>> DOWNLOADING ${filename}...\n`);
        const response = await axios({ method: 'get', url: url, responseType: 'stream' });
        const writer = fs.createWriteStream(targetPath);
        response.data.pipe(writer);
        
        writer.on('finish', () => {
            io.emit('log', `>>> INSTALLED ${filename} SUCCESSFULLY!\n`);
            if (type === 'jar') saveSettings({ jar: filename });
            res.json({ success: true });
        });
    } catch (err) {
        io.emit('log', `>>> ERROR: ${err.message}\n`);
        res.json({ success: false, msg: err.message });
    }
});

// Files
app.get('/api/files', checkAuth, (req, res) => {
    const dir = req.query.path || '.';
    if(dir.includes('..')) return res.json([]); 
    fs.readdir(path.join(__dirname, dir), { withFileTypes: true }, (err, files) => {
        if (err) return res.json([]);
        res.json(files.map(f => ({ name: f.name, isDir: f.isDirectory() })));
    });
});

app.post('/api/upload', checkAuth, upload.single('file'), (req, res) => {
    if (req.file) {
        if (req.file.originalname.endsWith('.zip')) {
            try {
                const zip = new AdmZip(req.file.path);
                zip.extractAllTo('.', true);
            } catch(e) { console.error(e); }
        } else {
            fs.moveSync(req.file.path, path.join('.', req.file.originalname), { overwrite: true });
        }
        fs.removeSync(req.file.path);
    }
    res.redirect('/');
});

// Socket
io.on('connection', (socket) => {
    socket.emit('history', consoleLog.join(''));
    socket.emit('status', mcProcess ? 'running' : 'stopped');
    socket.on('command', (cmd) => {
        if (mcProcess) mcProcess.stdin.write(cmd + "\n");
    });
});

const port = process.env.PORT || 8080;
server.listen(port, () => console.log(`PANEL RUNNING ON ${port}`));
EOF

# --- 5. FRONTEND ---
RUN mkdir public

# LOGIN HTML
RUN cat << 'EOF' > public/login.html
<!DOCTYPE html>
<html>
<head>
    <title>Login</title>
    <style>
        body{background:#111;color:#eee;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0}
        .box{background:#222;padding:30px;border-radius:10px;width:300px;text-align:center}
        input{display:block;margin:15px 0;padding:12px;width:100%;box-sizing:border-box;background:#333;border:1px solid #444;color:white;border-radius:5px}
        button{width:100%;padding:12px;background:#6200ea;color:white;border:none;border-radius:5px;cursor:pointer;font-weight:bold}
    </style>
</head>
<body>
<div class="box">
    <h2 id="title">Login</h2>
    <input type="text" id="user" placeholder="Username">
    <input type="password" id="pass" placeholder="Password">
    <button onclick="login()">Enter</button>
</div>
<script>
    fetch('/api/check-setup').then(r=>r.json()).then(d => {
        if(d.setupNeeded) document.getElementById('title').innerText = 'Create Admin';
    });
    async function login() {
        const u = document.getElementById('user').value;
        const p = document.getElementById('pass').value;
        const res = await fetch('/api/auth', { 
            method:'POST', headers:{'Content-Type':'application/json'}, 
            body: JSON.stringify({username:u, password:p}) 
        });
        const data = await res.json();
        if(data.success) location.href = '/';
        else alert(data.msg);
    }
</script>
</body>
</html>
EOF

# DASHBOARD HTML
RUN cat << 'EOF' > public/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>DIY MC Panel</title>
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet">
    <style>
        :root { --bg: #121212; --panel: #1e1e1e; --accent: #6200ea; --text: #e0e0e0; }
        body { margin: 0; font-family: sans-serif; background: var(--bg); color: var(--text); display: flex; height: 100vh; overflow: hidden; }
        .sidebar { width: 250px; background: var(--panel); padding: 20px; display: flex; flex-direction: column; gap: 10px; }
        .main { flex: 1; padding: 20px; display: flex; flex-direction: column; gap: 20px; overflow-y: auto; }
        .card { background: var(--panel); padding: 20px; border-radius: 12px; border: 1px solid #333; }
        
        button { padding: 10px; background: #333; color: white; border: none; border-radius: 6px; cursor: pointer; text-align: left; }
        button:hover { background: #444; }
        .btn-action { text-align: center; background: var(--accent); font-weight: bold; }
        .btn-red { background: #cf6679; color: black; text-align: center; }
        
        #terminal { background: #000; height: 400px; overflow-y: auto; padding: 15px; font-family: monospace; white-space: pre-wrap; font-size: 13px; border-radius: 8px; border: 1px solid #333; }
        input { padding: 10px; background: #222; border: 1px solid #444; color: white; border-radius: 6px; width: 100%; box-sizing: border-box; }
        
        .section { display: none; }
        .section.active { display: block; }
        .nav-active { background: var(--accent); }
    </style>
</head>
<body>

<div class="sidebar">
    <h2 style="margin-top:0"><i class="fa-solid fa-server"></i> PANEL v3</h2>
    <button onclick="show('console')" class="nav-btn nav-active" id="btn-console">Console</button>
    <button onclick="show('files')" class="nav-btn" id="btn-files">File Manager</button>
    <button onclick="show('settings')" class="nav-btn" id="btn-settings">Settings (RAM/Ver)</button>
    <div style="flex:1"></div>
    <button onclick="api('start')" class="btn-action">START SERVER</button>
    <button onclick="api('stop')" class="btn-red">STOP SERVER</button>
</div>

<div class="main">
    
    <div id="console" class="section active">
        <div class="card">
            <h3 style="margin-top:0">Terminal <span id="status" style="float:right; font-size:12px">...</span></h3>
            <div id="terminal"></div>
            <div style="display:flex; gap:10px; margin-top:10px">
                <input id="cmdInput" placeholder="Type command...">
                <button onclick="sendCmd()" class="btn-action" style="width:100px">Send</button>
            </div>
        </div>
        <div class="card" style="margin-top:20px">
             <h3>Quick Controls</h3>
             <div style="display:grid; grid-template-columns: repeat(4, 1fr); gap:10px">
                 <button class="btn-action" onclick="send('gamemode creative @a')">GM Creative</button>
                 <button class="btn-action" onclick="send('gamemode survival @a')">GM Survival</button>
                 <button class="btn-action" onclick="send('time set day')">Time Day</button>
                 <button class="btn-action" onclick="send('save-all')">Save World</button>
             </div>
        </div>
    </div>

    <div id="files" class="section">
        <div class="card">
            <h3>Upload</h3>
            <form action="/api/upload" method="post" enctype="multipart/form-data" style="display:flex; gap:10px">
                <input type="file" name="file" required>
                <button class="btn-action" style="width:150px">Upload</button>
            </form>
            <p style="font-size:12px; color:#aaa">Upload .zip files to auto-extract them.</p>
        </div>
        <div class="card" style="margin-top:20px">
            <h3>Files</h3>
            <div id="file-list"></div>
        </div>
    </div>

    <div id="settings" class="section">
        <div class="card">
            <h3>Server Configuration</h3>
            <p><strong>Custom RAM:</strong> Type amount (e.g. <code>512M</code>, <code>2G</code>, <code>4G</code>, <code>6.5G</code>)</p>
            <input type="text" id="ramInput" placeholder="e.g. 2G">
            
            <p><strong>Target JAR File:</strong> (Which file to run)</p>
            <input type="text" id="jarInput" placeholder="server.jar">
            
            <button onclick="saveSettings()" class="btn-action" style="margin-top:15px; width:100%">SAVE SETTINGS</button>
        </div>

        <div class="card" style="margin-top:20px">
            <h3>Custom Version Installer</h3>
            <p>Paste a download link to a Server JAR or Plugin.</p>
            <input type="text" id="installUrl" placeholder="https://..." style="margin-bottom:10px">
            <input type="text" id="installName" placeholder="Filename (e.g. server.jar)" style="margin-bottom:10px">
            <div style="display:flex; gap:10px">
                <button onclick="install('jar')" class="btn-action" style="flex:1">Install as Server JAR</button>
                <button onclick="install('plugin')" class="btn-action" style="flex:1">Install as Plugin</button>
            </div>
        </div>
    </div>

</div>

<script src="/socket.io/socket.io.js"></script>
<script>
    const socket = io();
    const term = document.getElementById('terminal');
    
    // UI Logic
    function show(id) {
        document.querySelectorAll('.section').forEach(el => el.classList.remove('active'));
        document.getElementById(id).classList.add('active');
        document.querySelectorAll('.nav-btn').forEach(el => el.classList.remove('nav-active'));
        document.getElementById('btn-'+id).classList.add('nav-active');
    }

    // Terminal
    socket.on('log', msg => {
        const d = document.createElement('div'); d.innerText = msg; term.appendChild(d);
        term.scrollTop = term.scrollHeight;
    });
    socket.on('status', s => document.getElementById('status').innerText = s.toUpperCase());

    function sendCmd() {
        const i = document.getElementById('cmdInput');
        if(i.value) { socket.emit('command', i.value); i.value=''; }
    }
    function send(c) { socket.emit('command', c); }
    document.getElementById('cmdInput').addEventListener('keypress', e => { if(e.key === 'Enter') sendCmd(); });

    // API
    function api(act) { fetch('/api/'+act, { method:'POST' }); }
    
    async function loadSettings() {
        const res = await fetch('/api/settings');
        const data = await res.json();
        document.getElementById('ramInput').value = data.ram;
        document.getElementById('jarInput').value = data.jar;
    }
    
    async function saveSettings() {
        const ram = document.getElementById('ramInput').value;
        const jar = document.getElementById('jarInput').value;
        await fetch('/api/settings', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ram, jar})
        });
        alert('Saved! Restart server to apply.');
    }
    
    async function install(type) {
        const url = document.getElementById('installUrl').value;
        const filename = document.getElementById('installName').value;
        if(!url || !filename) return alert('Fill fields');
        if(!confirm('Download ' + filename + '?')) return;
        
        show('console');
        fetch('/api/install', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({type, url, filename})
        });
    }

    async function loadFiles() {
        const res = await fetch('/api/files');
        const files = await res.json();
        const list = document.getElementById('file-list');
        list.innerHTML = '';
        files.forEach(f => {
            const d = document.createElement('div');
            d.style.padding = '10px';
            d.style.borderBottom = '1px solid #333';
            d.innerText = (f.isDir ? '📁 ' : '📄 ') + f.name;
            list.appendChild(d);
        });
    }

    loadSettings();
    loadFiles();
</script>
</body>
</html>
EOF

# --- 6. START ---
EXPOSE 8080 25565
CMD ["node", "server.js"]
