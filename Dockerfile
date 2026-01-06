FROM ubuntu:22.04

# --- 1. SETUP ENVIRONMENT ---
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080

# --- 2. INSTALL DEPENDENCIES ---
# Java 21 (Latest MC), Node.js, Curl, Wget, Zip
RUN apt-get update && apt-get install -y \
    curl wget git tar sudo unzip zip \
    openjdk-21-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# --- 3. SETUP APP DIRECTORY ---
WORKDIR /app

# Initialize & Install Modules
RUN npm init -y && \
    npm install express socket.io multer fs-extra body-parser express-session adm-zip axios

# Default Config & EULA
RUN echo "eula=true" > eula.txt
# Create a config file for RAM and JAR settings
RUN echo '{"ram": "2G", "jar": "server.jar"}' > settings.json

# --- 4. BACKEND CODE (server.js) ---
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

// --- STATE ---
const SETTINGS_FILE = 'settings.json';
const USERS_FILE = 'users.json';
let mcProcess = null;
let consoleLog = [];

// --- MIDDLEWARE ---
app.use(express.static('public'));
app.use(bodyParser.json());
app.use(session({ secret: 'supersecret', resave: false, saveUninitialized: true }));

// --- HELPERS ---
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

// 1. Auth (Login/Signup)
app.post('/api/auth', (req, res) => {
    const { username, password } = req.body;
    let users = {};
    if (fs.existsSync(USERS_FILE)) users = fs.readJsonSync(USERS_FILE, { throws: false }) || {};
    
    // First time signup
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

// 2. Server Control
app.post('/api/start', checkAuth, (req, res) => {
    if (mcProcess) return res.json({ msg: 'Server already running' });
    
    const settings = getSettings();
    const ram = settings.ram || "1G";
    const jar = settings.jar || "server.jar";
    
    if (!fs.existsSync(jar)) return res.json({ msg: 'Server JAR not found! Go to Settings to install one.' });

    io.emit('log', `\n>>> STARTING SERVER (${ram} RAM, ${jar})...\n`);
    
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

// 3. Settings (RAM & Version)
app.get('/api/settings', checkAuth, (req, res) => res.json(getSettings()));
app.post('/api/settings', checkAuth, (req, res) => {
    saveSettings(req.body);
    res.json({ success: true });
});

// 4. Installer (Version & Plugins)
app.post('/api/install', checkAuth, async (req, res) => {
    const { url, type, filename } = req.body; // type = 'jar' or 'plugin'
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
        io.emit('log', `>>> ERROR DOWNLOADING: ${err.message}\n`);
        res.json({ success: false, msg: err.message });
    }
});

// 5. File Manager
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
                zip.extractAllTo('.', true); // Extract to root
            } catch(e) { console.error(e); }
        } else {
            fs.moveSync(req.file.path, path.join('.', req.file.originalname), { overwrite: true });
        }
        fs.removeSync(req.file.path); // Cleanup temp
    }
    res.redirect('/');
});

// --- SOCKET IO ---
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

# --- 5. FRONTEND FILES (HTML/CSS/JS) ---
RUN mkdir public

# --- INDEX.HTML (THE UI) ---
RUN cat << 'EOF' > public/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Railway MC Panel</title>
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet">
    <style>
        :root { --bg: #121212; --panel: #1e1e1e; --accent: #6200ea; --text: #e0e0e0; --red: #cf6679; --green: #03dac6; }
        body { margin: 0; font-family: 'Segoe UI', sans-serif; background: var(--bg); color: var(--text); display: flex; height: 100vh; overflow: hidden; }
        
        /* Sidebar */
        .sidebar { width: 250px; background: var(--panel); display: flex; flex-direction: column; padding: 20px; box-shadow: 2px 0 10px rgba(0,0,0,0.5); }
        .sidebar h2 { margin: 0 0 20px 0; color: var(--accent); letter-spacing: 1px; }
        .nav-btn { background: transparent; border: none; color: #888; padding: 15px; text-align: left; cursor: pointer; font-size: 16px; border-radius: 8px; transition: 0.2s; display: flex; align-items: center; gap: 10px; }
        .nav-btn:hover, .nav-btn.active { background: #333; color: white; }
        .nav-btn i { width: 20px; }
        
        /* Main Content */
        .main { flex: 1; padding: 20px; display: flex; flex-direction: column; gap: 20px; overflow-y: auto; }
        .card { background: var(--panel); padding: 20px; border-radius: 12px; border: 1px solid #333; }
        h3 { margin-top: 0; border-bottom: 1px solid #333; padding-bottom: 10px; }

        /* Terminal */
        #terminal { background: #000; height: 400px; overflow-y: auto; padding: 15px; font-family: monospace; white-space: pre-wrap; font-size: 13px; color: #ccc; border-radius: 8px; border: 1px solid #333; }
        .input-group { display: flex; gap: 10px; margin-top: 10px; }
        input[type="text"], select { flex: 1; padding: 12px; border-radius: 6px; border: 1px solid #444; background: #222; color: white; outline: none; }
        
        /* Buttons */
        .btn { padding: 10px 20px; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; transition: 0.2s; }
        .btn-primary { background: var(--accent); color: white; }
        .btn-success { background: var(--green); color: black; }
        .btn-danger { background: var(--red); color: black; }
        .btn:hover { opacity: 0.9; transform: translateY(-1px); }
        .status-badge { padding: 5px 10px; border-radius: 4px; font-size: 12px; font-weight: bold; text-transform: uppercase; }
        .status-running { background: rgba(3, 218, 198, 0.2); color: var(--green); }
        .status-stopped { background: rgba(207, 102, 121, 0.2); color: var(--red); }

        /* File List */
        .file-item { display: flex; justify-content: space-between; padding: 10px; border-bottom: 1px solid #333; cursor: pointer; }
        .file-item:hover { background: #2a2a2a; }

        /* Sections */
        .section { display: none; }
        .section.active { display: block; }
        
        /* Login Overlay */
        #login-overlay { position: fixed; top:0; left:0; width:100%; height:100%; background: var(--bg); z-index: 999; display: flex; justify-content: center; align-items: center; }
        .login-box { background: var(--panel); padding: 40px; border-radius: 12px; width: 300px; text-align: center; }
    </style>
</head>
<body>

<div id="login-overlay">
    <div class="login-box">
        <h2 id="login-title">Admin Login</h2>
        <input type="text" id="username" placeholder="Username" style="margin-bottom: 10px;">
        <input type="password" id="password" placeholder="Password" style="margin-bottom: 20px;">
        <button class="btn btn-primary" style="width:100%" onclick="login()">Enter Panel</button>
    </div>
</div>

<div class="sidebar">
    <h2><i class="fa-solid fa-cube"></i> MC PANEL</h2>
    <button class="nav-btn active" onclick="show('console')"><i class="fa-solid fa-terminal"></i> Console</button>
    <button class="nav-btn" onclick="show('controls')"><i class="fa-solid fa-gamepad"></i> Game Controls</button>
    <button class="nav-btn" onclick="show('files')"><i class="fa-solid fa-folder"></i> File Manager</button>
    <button class="nav-btn" onclick="show('settings')"><i class="fa-solid fa-gear"></i> Settings</button>
</div>

<div class="main">
    
    <div id="console" class="section active">
        <div class="card">
            <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px;">
                <h3>Server Console</h3>
                <span id="status-badge" class="status-badge status-stopped">STOPPED</span>
            </div>
            <div id="terminal"></div>
            <div class="input-group">
                <input type="text" id="cmdInput" placeholder="Type command (e.g., op player, gamemode creative)...">
                <button class="btn btn-primary" onclick="sendCmd()">Send</button>
            </div>
            <div style="margin-top: 15px; display:flex; gap: 10px;">
                <button class="btn btn-success" onclick="api('start')"><i class="fa-solid fa-play"></i> START</button>
                <button class="btn btn-danger" onclick="api('stop')"><i class="fa-solid fa-stop"></i> STOP</button>
            </div>
        </div>
    </div>

    <div id="controls" class="section">
        <div class="card">
            <h3>Quick Actions</h3>
            <div style="display:grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px;">
                <button class="btn btn-primary" onclick="send('time set day')">Time Day</button>
                <button class="btn btn-primary" onclick="send('time set night')">Time Night</button>
                <button class="btn btn-primary" onclick="send('weather clear')">Clear Weather</button>
                <button class="btn btn-primary" onclick="send('gamerule keepInventory true')">Keep Inventory</button>
            </div>
        </div>
        <div class="card" style="margin-top:20px;">
            <h3>Player Management</h3>
            <div class="input-group">
                <input type="text" id="targetPlayer" placeholder="Player Name">
            </div>
            <div style="margin-top:10px; display:flex; gap:10px;">
                <button class="btn btn-success" onclick="playerAction('op')">OP</button>
                <button class="btn btn-danger" onclick="playerAction('ban')">BAN</button>
                <button class="btn btn-danger" onclick="playerAction('kick')">KICK</button>
                <button class="btn btn-primary" onclick="playerAction('gamemode creative')">CREATIVE</button>
                <button class="btn btn-primary" onclick="playerAction('gamemode survival')">SURVIVAL</button>
            </div>
        </div>
    </div>

    <div id="files" class="section">
        <div class="card">
            <h3>Upload Map / Plugins</h3>
            <form action="/api/upload" method="post" enctype="multipart/form-data" class="input-group">
                <input type="file" name="file" required>
                <button class="btn btn-success">Upload</button>
            </form>
            <small>Supports .zip (auto-extracts) and .jar</small>
        </div>
        <div class="card" style="margin-top:20px;">
            <h3>File Browser</h3>
            <div id="file-list"></div>
        </div>
    </div>

    <div id="settings" class="section">
        <div class="card">
            <h3>Server Configuration</h3>
            <label>Max RAM Allocation</label>
            <div class="input-group">
                <select id="ramSelect">
                    <option value="1G">1 GB</option>
                    <option value="2G">2 GB</option>
                    <option value="4G">4 GB</option>
                    <option value="8G">8 GB</option>
                </select>
                <button class="btn btn-primary" onclick="saveSettings()">Save RAM</button>
            </div>
        </div>

        <div class="card" style="margin-top:20px;">
            <h3>Version Installer</h3>
            <p>Click to install a new server version (Will overwrite server.jar!).</p>
            <div style="display:flex; gap:10px; flex-wrap:wrap;">
                <button class="btn btn-primary" onclick="install('jar', 'https://api.papermc.io/v2/projects/paper/versions/1.20.4/builds/496/downloads/paper-1.20.4-496.jar', 'server.jar')">Install 1.20.4</button>
                <button class="btn btn-primary" onclick="install('jar', 'https://api.papermc.io/v2/projects/paper/versions/1.21/builds/130/downloads/paper-1.21-130.jar', 'server.jar')">Install 1.21</button>
            </div>
        </div>

        <div class="card" style="margin-top:20px;">
            <h3>Plugin Installer</h3>
            <div class="input-group">
                <input type="text" id="pluginUrl" placeholder="Direct Download URL (must end in .jar)">
                <input type="text" id="pluginName" placeholder="Filename (e.g. Essentials.jar)">
                <button class="btn btn-success" onclick="installPlugin()">Install</button>
            </div>
        </div>
    </div>

</div>

<script src="/socket.io/socket.io.js"></script>
<script>
    const socket = io();
    const term = document.getElementById('terminal');
    
    // --- LOGIN ---
    fetch('/api/check-setup').then(r=>r.json()).then(d => {
        if(d.setupNeeded) document.getElementById('login-title').innerText = 'Create Admin Account';
    });

    async function login() {
        const u = document.getElementById('username').value;
        const p = document.getElementById('password').value;
        const res = await fetch('/api/auth', { 
            method:'POST', headers:{'Content-Type':'application/json'}, 
            body: JSON.stringify({username:u, password:p}) 
        });
        const data = await res.json();
        if(data.success) {
            document.getElementById('login-overlay').style.display = 'none';
            loadFiles();
            loadSettings();
        } else alert(data.msg);
    }

    // --- NAVIGATION ---
    function show(id) {
        document.querySelectorAll('.section').forEach(el => el.classList.remove('active'));
        document.getElementById(id).classList.add('active');
        document.querySelectorAll('.nav-btn').forEach(el => el.classList.remove('active'));
        event.currentTarget.classList.add('active');
    }

    // --- TERMINAL & SOCKET ---
    socket.on('log', msg => {
        const div = document.createElement('div'); div.textContent = msg;
        term.appendChild(div);
        term.scrollTop = term.scrollHeight;
    });
    socket.on('status', s => {
        const b = document.getElementById('status-badge');
        b.className = 'status-badge status-' + s;
        b.innerText = s.toUpperCase();
    });

    function sendCmd() {
        const i = document.getElementById('cmdInput');
        if(i.value) { socket.emit('command', i.value); i.value = ''; }
    }
    // Allow Enter key
    document.getElementById('cmdInput').addEventListener('keypress', e => { if(e.key === 'Enter') sendCmd(); });

    // --- CONTROLS ---
    function api(action) { fetch('/api/' + action, { method: 'POST' }); }
    function send(cmd) { socket.emit('command', cmd); }
    function playerAction(act) {
        const p = document.getElementById('targetPlayer').value;
        if(p) send(act + ' ' + p); else alert('Enter player name');
    }

    // --- SETTINGS & INSTALLER ---
    async function loadSettings() {
        const res = await fetch('/api/settings');
        const data = await res.json();
        if(data.ram) document.getElementById('ramSelect').value = data.ram;
    }
    async function saveSettings() {
        const ram = document.getElementById('ramSelect').value;
        await fetch('/api/settings', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ram})
        });
        alert('Saved! Restart server to apply.');
    }
    async function install(type, url, filename) {
        if(!confirm('This will download file and might overwrite existing ones. Continue?')) return;
        alert('Download started in background. Check Console.');
        fetch('/api/install', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({type, url, filename})
        });
        show('console');
    }
    function installPlugin() {
        const url = document.getElementById('pluginUrl').value;
        const name = document.getElementById('pluginName').value;
        if(url && name) install('plugin', url, name);
    }

    // --- FILES ---
    async function loadFiles() {
        const res = await fetch('/api/files');
        const files = await res.json();
        const list = document.getElementById('file-list');
        list.innerHTML = '';
        files.forEach(f => {
            const d = document.createElement('div');
            d.className = 'file-item';
            d.innerHTML = `<span>${f.isDir ? '📁' : '📄'} ${f.name}</span>`;
            list.appendChild(d);
        });
    }
</script>
</body>
</html>
EOF

# --- 6. START COMMAND ---
EXPOSE 8080 25565
CMD ["node", "server.js"]
