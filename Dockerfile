FROM ubuntu:22.04

# --- 1. SETUP ENVIRONMENT ---
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080

# --- 2. INSTALL DEPENDENCIES ---
# Install Java 21, Node.js, and utilities
RUN apt-get update && apt-get install -y \
    curl wget git tar sudo unzip zip \
    openjdk-21-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# --- 3. SETUP APP DIRECTORY ---
WORKDIR /app

# Initialize Node and install dependencies (added axios for downloading files)
RUN npm init -y && \
    npm install express socket.io multer fs-extra body-parser express-session adm-zip axios

# Default Config & EULA
RUN echo "eula=true" > eula.txt

# --- 4. CREATE BACKEND (server.js) ---
# We use a quoted heredoc ('EOF') so ${} syntax in JS is not interpreted by Docker
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

// --- CONSTANTS & STATE ---
const USER_FILE = 'users.json';
const CONFIG_FILE = 'server_config.json';
const PLUGINS_DIR = 'plugins';

// Default Config
const DEFAULT_CONFIG = {
    ram: "2", // GB
    version: "1.20.4",
    jar: "server.jar",
    autoRestart: true
};

let mcProcess = null;
let logs = [];
let serverStatus = 'offline'; // offline, starting, online, stopping

// Ensure Dirs
fs.ensureDirSync(PLUGINS_DIR);

// --- HELPERS ---
function getConfig() {
    if (!fs.existsSync(CONFIG_FILE)) fs.writeJsonSync(CONFIG_FILE, DEFAULT_CONFIG);
    return fs.readJsonSync(CONFIG_FILE);
}

function saveConfig(cfg) {
    fs.writeJsonSync(CONFIG_FILE, cfg);
}

// Download PaperMC Logic
async function downloadServerJar(version) {
    try {
        io.emit('log', `\n[System] Fetching latest build for Paper ${version}...`);
        // Get Project Info
        const projectUrl = `https://api.papermc.io/v2/projects/paper/versions/${version}`;
        const projectRes = await axios.get(projectUrl);
        const builds = projectRes.data.builds;
        const latestBuild = builds[builds.length - 1];
        
        const downloadUrl = `https://api.papermc.io/v2/projects/paper/versions/${version}/builds/${latestBuild}/downloads/paper-${version}-${latestBuild}.jar`;
        
        io.emit('log', `[System] Downloading from: ${downloadUrl}`);
        
        const writer = fs.createWriteStream('server.jar');
        const response = await axios({
            url: downloadUrl,
            method: 'GET',
            responseType: 'stream'
        });

        response.data.pipe(writer);

        return new Promise((resolve, reject) => {
            writer.on('finish', resolve);
            writer.on('error', reject);
        });
    } catch (error) {
        io.emit('log', `[System] Error downloading server: ${error.message}`);
        throw error;
    }
}

// --- EXPRESS MIDDLEWARE ---
app.use(express.static('public'));
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(session({ secret: 'super-secret-key-change-me', resave: false, saveUninitialized: true }));

function checkAuth(req, res, next) {
    if (req.session.loggedin) next();
    else res.redirect('/login.html');
}

// --- API ROUTES ---

// Auth
app.get('/api/check-setup', (req, res) => {
    let users = {};
    if (fs.existsSync(USER_FILE)) users = fs.readJsonSync(USER_FILE, { throws: false }) || {};
    res.json({ setupNeeded: Object.keys(users).length === 0 });
});

app.post('/api/auth', (req, res) => {
    const { username, password, action } = req.body;
    let users = fs.existsSync(USER_FILE) ? fs.readJsonSync(USER_FILE, { throws: false }) || {} : {};

    if (action === 'signup') {
        if (Object.keys(users).length > 0) return res.json({ success: false, msg: 'Admin already exists.' });
        users[username] = password;
        fs.writeJsonSync(USER_FILE, users);
        req.session.loggedin = true;
        return res.json({ success: true });
    } else {
        if (users[username] && users[username] === password) {
            req.session.loggedin = true;
            return res.json({ success: true });
        }
        return res.json({ success: false, msg: 'Invalid credentials' });
    }
});

app.get('/api/logout', (req, res) => {
    req.session.destroy();
    res.redirect('/login.html');
});

// Dashboard
app.get('/', checkAuth, (req, res) => { res.sendFile(path.join(__dirname, 'public/index.html')); });

// Settings
app.get('/api/settings', checkAuth, (req, res) => {
    res.json(getConfig());
});

app.post('/api/settings', checkAuth, async (req, res) => {
    const newConfig = req.body;
    const oldConfig = getConfig();
    saveConfig(newConfig);

    // If version changed, we need to download new jar
    if (newConfig.version !== oldConfig.version) {
        if (serverStatus !== 'offline') {
            stopServer();
            // Wait for stop
            setTimeout(async () => {
                try {
                    await downloadServerJar(newConfig.version);
                    startServer();
                } catch(e) { console.error(e); }
            }, 3000);
        } else {
            try {
                await downloadServerJar(newConfig.version);
            } catch(e) { console.error(e); }
        }
    }
    
    res.json({ success: true });
});

// Plugins
app.get('/api/plugins', checkAuth, (req, res) => {
    fs.readdir(PLUGINS_DIR, (err, files) => {
        if(err) return res.json([]);
        res.json(files.filter(f => f.endsWith('.jar')));
    });
});

app.post('/api/plugins/upload', checkAuth, upload.single('file'), (req, res) => {
    if(req.file) {
        fs.moveSync(req.file.path, path.join(PLUGINS_DIR, req.file.originalname), { overwrite: true });
    }
    res.redirect('/');
});

app.post('/api/plugins/install-url', checkAuth, async (req, res) => {
    const { url } = req.body;
    try {
        const fileName = url.split('/').pop();
        const response = await axios({ url, method: 'GET', responseType: 'stream' });
        const writer = fs.createWriteStream(path.join(PLUGINS_DIR, fileName));
        response.data.pipe(writer);
        res.json({ success: true });
    } catch(e) {
        res.json({ success: false, msg: e.message });
    }
});

app.post('/api/plugins/delete', checkAuth, (req, res) => {
    try {
        fs.removeSync(path.join(PLUGINS_DIR, req.body.filename));
        res.json({ success: true });
    } catch(e) { res.json({ success: false }); }
});


// --- SERVER CONTROL ---

function startServer() {
    if (mcProcess) return;
    const config = getConfig();

    // Check if jar exists, if not, try download
    if (!fs.existsSync('server.jar')) {
        io.emit('log', '[System] server.jar not found. Downloading...');
        downloadServerJar(config.version).then(() => startServer()).catch(err => {
            io.emit('log', '[System] Failed to download server.');
        });
        return;
    }

    serverStatus = 'starting';
    io.emit('status', serverStatus);
    io.emit('log', `\n[System] Starting Server with ${config.ram}GB RAM...`);

    const ramArgs = [`-Xmx${config.ram}G`, `-Xms${config.ram}G`];
    const args = [...ramArgs, '-jar', 'server.jar', 'nogui'];

    mcProcess = spawn('java', args);

    mcProcess.stdout.on('data', (data) => {
        const line = data.toString();
        logs.push(line);
        if (logs.length > 1000) logs.shift();
        io.emit('log', line);
        if (line.includes('Done')) {
            serverStatus = 'online';
            io.emit('status', serverStatus);
        }
    });

    mcProcess.stderr.on('data', (data) => {
        const line = data.toString();
        io.emit('log', line);
    });

    mcProcess.on('close', (code) => {
        mcProcess = null;
        serverStatus = 'offline';
        const msg = `\n[System] Server stopped (Code ${code})\n`;
        logs.push(msg);
        io.emit('log', msg);
        io.emit('status', serverStatus);
    });
}

function stopServer() {
    if (mcProcess) {
        serverStatus = 'stopping';
        io.emit('status', serverStatus);
        mcProcess.stdin.write('stop\n');
    }
}

// --- SOCKET.IO ---
io.on('connection', (socket) => {
    socket.emit('history', logs.join(''));
    socket.emit('status', serverStatus);

    socket.on('command', (cmd) => {
        console.log('CMD:', cmd);
        if (cmd === '__start__') startServer();
        else if (cmd === '__stop__') stopServer();
        else if (cmd === '__restart__') {
            stopServer();
            setTimeout(startServer, 5000);
        }
        else if (mcProcess && mcProcess.stdin) {
            mcProcess.stdin.write(cmd + '\n');
        }
    });
});

// Boot Check
const cfg = getConfig();
if(!fs.existsSync('server.jar')) {
    console.log("Initial download of server jar...");
    downloadServerJar(cfg.version);
}

const port = process.env.PORT || 8080;
server.listen(port, () => console.log(`Dashboard running on port ${port}`));
EOF

# --- 5. CREATE FRONTEND ---

RUN mkdir public

# --- LOGIN HTML ---
RUN cat << 'EOF' > public/login.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Admin Login</title>
<style>
    :root { --primary: #6366f1; --bg: #0f172a; --card: #1e293b; --text: #f8fafc; }
    body { background: var(--bg); color: var(--text); font-family: 'Segoe UI', sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
    .card { background: var(--card); padding: 2rem; border-radius: 12px; box-shadow: 0 10px 25px rgba(0,0,0,0.5); width: 100%; max-width: 350px; text-align: center; border: 1px solid #334155; }
    h2 { margin-bottom: 1.5rem; color: var(--primary); }
    input { width: 100%; padding: 12px; margin-bottom: 10px; background: #334155; border: 1px solid #475569; color: white; border-radius: 6px; box-sizing: border-box; outline: none; }
    input:focus { border-color: var(--primary); }
    button { width: 100%; padding: 12px; background: var(--primary); color: white; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; transition: 0.3s; }
    button:hover { filter: brightness(1.1); }
</style>
</head>
<body>
<div class="card">
    <h2 id="title">Panel Login</h2>
    <form id="authForm">
        <input type="text" id="user" placeholder="Username" required>
        <input type="password" id="pass" placeholder="Password" required>
        <button type="submit">Access Console</button>
    </form>
</div>
<script>
    fetch('/api/check-setup').then(r=>r.json()).then(d => {
        if(d.setupNeeded) {
            document.getElementById('title').innerText = 'Create Admin Account';
            document.getElementById('authForm').dataset.action = 'signup';
        }
    });
    document.getElementById('authForm').onsubmit = async (e) => {
        e.preventDefault();
        const user = document.getElementById('user').value;
        const pass = document.getElementById('pass').value;
        const action = e.target.dataset.action || 'login';
        const res = await fetch('/api/auth', {
            method: 'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({username:user, password:pass, action})
        });
        const data = await res.json();
        if(data.success) location.href = '/';
        else alert(data.msg);
    };
</script>
</body>
</html>
EOF

# --- MAIN DASHBOARD HTML ---
RUN cat << 'EOF' > public/index.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pro MC Panel</title>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css" rel="stylesheet">
<style>
    :root {
        --bg: #09090b; --sidebar: #18181b; --card: #27272a; 
        --text-main: #e4e4e7; --text-muted: #a1a1aa;
        --accent: #6366f1; --danger: #ef4444; --success: #22c55e;
        --term-bg: #101012;
    }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: 'Segoe UI', system-ui, sans-serif; background: var(--bg); color: var(--text-main); display: flex; height: 100vh; overflow: hidden; }
    
    /* Sidebar */
    .sidebar { width: 260px; background: var(--sidebar); display: flex; flex-direction: column; padding: 20px; border-right: 1px solid #3f3f46; }
    .logo { font-size: 20px; font-weight: bold; color: var(--accent); margin-bottom: 30px; display: flex; align-items: center; gap: 10px; }
    .nav-item { padding: 12px 15px; margin-bottom: 5px; border-radius: 8px; cursor: pointer; color: var(--text-muted); transition: 0.2s; display: flex; align-items: center; gap: 12px; }
    .nav-item:hover, .nav-item.active { background: var(--card); color: var(--text-main); }
    .status-dot { width: 10px; height: 10px; border-radius: 50%; background: #555; margin-left: auto; box-shadow: 0 0 8px #555; }
    .status-online { background: var(--success); box-shadow: 0 0 8px var(--success); }
    .status-offline { background: var(--danger); box-shadow: 0 0 8px var(--danger); }
    
    /* Main Content */
    .main { flex: 1; padding: 30px; overflow-y: auto; display: flex; flex-direction: column; gap: 20px; position: relative; }
    .page { display: none; animation: fadeIn 0.3s; height: 100%; flex-direction: column; }
    .page.active { display: flex; }
    @keyframes fadeIn { from { opacity: 0; transform: translateY(5px); } to { opacity: 1; transform: translateY(0); } }

    /* Header */
    .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
    h1 { margin: 0; font-size: 24px; }
    .actions { display: flex; gap: 10px; }

    /* Buttons */
    .btn { border: none; padding: 10px 20px; border-radius: 8px; font-weight: 600; cursor: pointer; transition: 0.2s; display: flex; align-items: center; gap: 8px; }
    .btn-primary { background: var(--accent); color: white; }
    .btn-primary:hover { background: #4f46e5; }
    .btn-danger { background: var(--danger); color: white; }
    .btn-success { background: var(--success); color: white; }
    .btn-secondary { background: var(--card); color: var(--text-main); border: 1px solid #3f3f46; }
    .btn-secondary:hover { background: #3f3f46; }

    /* Terminal */
    .terminal-container { flex: 1; display: flex; flex-direction: column; background: var(--term-bg); border-radius: 12px; border: 1px solid #3f3f46; overflow: hidden; }
    #terminal { flex: 1; padding: 15px; overflow-y: auto; font-family: 'Consolas', monospace; font-size: 13px; white-space: pre-wrap; color: #d4d4d8; }
    .cmd-bar { display: flex; padding: 10px; background: #18181b; border-top: 1px solid #3f3f46; }
    #cmdInput { flex: 1; background: transparent; border: none; color: white; outline: none; font-family: monospace; }
    
    /* Settings Form */
    .settings-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 20px; }
    .card-box { background: var(--card); padding: 20px; border-radius: 12px; border: 1px solid #3f3f46; }
    .form-group { margin-bottom: 15px; }
    .form-group label { display: block; margin-bottom: 8px; color: var(--text-muted); font-size: 14px; }
    .form-control { width: 100%; padding: 12px; background: #18181b; border: 1px solid #3f3f46; border-radius: 8px; color: white; outline: none; transition: 0.2s; }
    .form-control:focus { border-color: var(--accent); }

    /* Plugin List */
    .plugin-item { display: flex; justify-content: space-between; align-items: center; padding: 15px; background: #18181b; border-bottom: 1px solid #3f3f46; }
    .plugin-item:first-child { border-radius: 8px 8px 0 0; }
    .plugin-item:last-child { border-radius: 0 0 8px 8px; border-bottom: none; }
    
    /* Log Colors */
    .log-info { color: #60a5fa; }
    .log-warn { color: #facc15; }
    .log-error { color: #f87171; }
</style>
</head>
<body>

<div class="sidebar">
    <div class="logo"><i class="fas fa-cube"></i> MC Panel Pro</div>
    <div class="nav-item active" onclick="showPage('console')"><i class="fas fa-terminal"></i> Console</div>
    <div class="nav-item" onclick="showPage('settings')"><i class="fas fa-sliders-h"></i> Settings</div>
    <div class="nav-item" onclick="showPage('plugins')"><i class="fas fa-plug"></i> Plugins</div>
    <div class="nav-item" onclick="location.href='/api/logout'"><i class="fas fa-sign-out-alt"></i> Logout</div>
    
    <div style="margin-top:auto; padding: 15px; background: #111; border-radius: 8px;">
        <small style="color:#888">Status</small>
        <div style="display:flex; align-items:center; margin-top:5px; font-weight:bold">
            <span id="statusText">Offline</span>
            <div id="statusDot" class="status-dot"></div>
        </div>
    </div>
</div>

<div class="main">
    
    <!-- CONSOLE PAGE -->
    <div id="console" class="page active">
        <div class="header">
            <h1>Server Console</h1>
            <div class="actions">
                <button class="btn btn-success" onclick="socket.emit('command', '__start__')"><i class="fas fa-play"></i> Start</button>
                <button class="btn btn-secondary" onclick="socket.emit('command', '__restart__')"><i class="fas fa-redo"></i> Restart</button>
                <button class="btn btn-danger" onclick="socket.emit('command', '__stop__')"><i class="fas fa-stop"></i> Stop</button>
            </div>
        </div>
        <div class="terminal-container">
            <div id="terminal"></div>
            <div class="cmd-bar">
                <span style="color:var(--accent); margin-right:10px;">></span>
                <input id="cmdInput" placeholder="Type a command..." autocomplete="off">
            </div>
        </div>
    </div>

    <!-- SETTINGS PAGE -->
    <div id="settings" class="page">
        <div class="header"><h1>Server Settings</h1></div>
        <div class="settings-grid">
            <div class="card-box">
                <h3><i class="fas fa-memory"></i> Performance</h3>
                <div class="form-group">
                    <label>Allocated RAM (GB)</label>
                    <input type="number" id="ramInput" class="form-control" placeholder="Example: 4">
                </div>
            </div>
            <div class="card-box">
                <h3><i class="fas fa-gamepad"></i> Game Version</h3>
                <div class="form-group">
                    <label>Minecraft Version (PaperMC)</label>
                    <input type="text" id="versionInput" class="form-control" placeholder="Example: 1.20.4">
                    <small style="color:#666">Changing this will stop server, download new jar, and restart.</small>
                </div>
            </div>
        </div>
        <div style="margin-top: 20px; text-align: right;">
            <button class="btn btn-primary" onclick="saveSettings()"><i class="fas fa-save"></i> Save & Apply</button>
        </div>
    </div>

    <!-- PLUGINS PAGE -->
    <div id="plugins" class="page">
        <div class="header">
            <h1>Plugin Manager</h1>
            <div class="actions">
                <button class="btn btn-primary" onclick="document.getElementById('plUpload').click()"><i class="fas fa-upload"></i> Upload .jar</button>
                <input type="file" id="plUpload" style="display:none" onchange="uploadPlugin(this)">
            </div>
        </div>

        <div class="card-box" style="margin-bottom: 20px;">
            <h3>Install from URL</h3>
            <div style="display:flex; gap:10px">
                <input id="urlInput" class="form-control" placeholder="https://example.com/plugin.jar">
                <button class="btn btn-secondary" onclick="installUrl()">Install</button>
            </div>
        </div>

        <div class="card-box">
            <h3>Installed Plugins</h3>
            <div id="pluginList"></div>
        </div>
    </div>

</div>

<script src="/socket.io/socket.io.js"></script>
<script>
    const socket = io();
    const term = document.getElementById('terminal');
    let autoScroll = true;

    // --- NAVIGATION ---
    function showPage(id) {
        document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
        document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
        document.getElementById(id).classList.add('active');
        event.currentTarget.classList.add('active');
        if(id === 'plugins') loadPlugins();
        if(id === 'settings') loadSettings();
    }

    // --- SOCKET LOGIC ---
    socket.on('log', (msg) => {
        const span = document.createElement('div');
        if(msg.toLowerCase().includes('error')) span.className = 'log-error';
        else if(msg.toLowerCase().includes('warn')) span.className = 'log-warn';
        else if(msg.includes('[System]')) span.className = 'log-info';
        
        span.textContent = msg;
        term.appendChild(span);
        if (autoScroll) term.scrollTop = term.scrollHeight;
    });

    socket.on('history', (data) => {
        term.textContent = data;
        term.scrollTop = term.scrollHeight;
    });

    socket.on('status', (status) => {
        const dot = document.getElementById('statusDot');
        const text = document.getElementById('statusText');
        text.textContent = status.toUpperCase();
        dot.className = 'status-dot'; // reset
        if(status === 'online') dot.classList.add('status-online');
        else if(status === 'offline') dot.classList.add('status-offline');
        else dot.style.background = '#facc15'; // starting/stopping yellow
    });

    // --- CONSOLE INPUT ---
    document.getElementById('cmdInput').addEventListener('keydown', (e) => {
        if(e.key === 'Enter') {
            const cmd = e.target.value;
            if(cmd) {
                socket.emit('command', cmd);
                e.target.value = '';
            }
        }
    });

    term.addEventListener('scroll', () => {
        autoScroll = (term.scrollTop + term.clientHeight >= term.scrollHeight - 20);
    });

    // --- SETTINGS ---
    function loadSettings() {
        fetch('/api/settings').then(r=>r.json()).then(data => {
            document.getElementById('ramInput').value = data.ram;
            document.getElementById('versionInput').value = data.version;
        });
    }

    function saveSettings() {
        const ram = document.getElementById('ramInput').value;
        const version = document.getElementById('versionInput').value;
        fetch('/api/settings', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ ram, version })
        }).then(r=>r.json()).then(d => {
            if(d.success) alert('Settings saved! Server may restart if version changed.');
        });
    }

    // --- PLUGINS ---
    function loadPlugins() {
        fetch('/api/plugins').then(r=>r.json()).then(files => {
            const list = document.getElementById('pluginList');
            list.innerHTML = '';
            if(files.length === 0) list.innerHTML = '<div style="padding:15px; color:#666">No plugins installed.</div>';
            files.forEach(f => {
                list.innerHTML += `
                    <div class="plugin-item">
                        <span><i class="fas fa-cube"></i> ${f}</span>
                        <button class="btn btn-danger" style="padding:5px 10px; font-size:12px" onclick="deletePlugin('${f}')"><i class="fas fa-trash"></i></button>
                    </div>`;
            });
        });
    }

    function uploadPlugin(input) {
        if(!input.files[0]) return;
        const fd = new FormData();
        fd.append('file', input.files[0]);
        fetch('/api/plugins/upload', { method: 'POST', body: fd }).then(() => {
            loadPlugins();
            alert('Plugin uploaded! Restart server to apply.');
        });
    }

    function installUrl() {
        const url = document.getElementById('urlInput').value;
        if(!url) return;
        fetch('/api/plugins/install-url', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ url })
        }).then(r=>r.json()).then(d => {
            if(d.success) { loadPlugins(); alert('Plugin installed!'); }
            else alert('Error: ' + d.msg);
        });
    }

    function deletePlugin(filename) {
        if(!confirm('Delete ' + filename + '?')) return;
        fetch('/api/plugins/delete', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ filename })
        }).then(() => loadPlugins());
    }

</script>
</body>
</html>
EOF

# --- 6. EXPOSE PORTS ---
EXPOSE 8080 25565

# --- 7. START ---
CMD ["node", "server.js"]
