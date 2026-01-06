FROM ubuntu:22.04

# --- 1. SETUP ENVIRONMENT ---
ENV DEBIAN_FRONTEND=noninteractive
ENV PANEL_PORT=20000

# --- 2. INSTALL DEPENDENCIES ---
RUN apt-get update && apt-get install -y \
    curl wget git tar sudo unzip zip \
    openjdk-21-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# --- 3. SETUP APP DIRECTORY ---
WORKDIR /app

# Initialize Node and install dependencies
RUN npm init -y && \
    npm install express socket.io multer fs-extra body-parser express-session adm-zip axios

# Accept EULA
RUN echo "eula=true" > eula.txt

# --- 4. CREATE BACKEND (server.js) ---
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

// --- CONSTANTS ---
const USER_FILE = 'users.json';
const CONFIG_FILE = 'server_config.json';
const PROPS_FILE = 'server.properties';
const PLUGINS_DIR = 'plugins';

// Default Config
const DEFAULT_CONFIG = {
    ram: "4",
    version: "1.20.4"
};

let mcProcess = null;
let logs = [];
let serverStatus = 'offline';

fs.ensureDirSync(PLUGINS_DIR);

// --- HELPERS ---

function getConfig() {
    if (!fs.existsSync(CONFIG_FILE)) fs.writeJsonSync(CONFIG_FILE, DEFAULT_CONFIG);
    return fs.readJsonSync(CONFIG_FILE);
}

function saveConfig(cfg) {
    fs.writeJsonSync(CONFIG_FILE, cfg);
}

// Read server.properties to get current render distance
function getProperties() {
    if (!fs.existsSync(PROPS_FILE)) return { viewDistance: 10 };
    const content = fs.readFileSync(PROPS_FILE, 'utf8');
    const match = content.match(/view-distance=(\d+)/);
    return { viewDistance: match ? parseInt(match[1]) : 10 };
}

// Update server.properties safely
function updateProperties(key, value) {
    let content = "";
    if (fs.existsSync(PROPS_FILE)) content = fs.readFileSync(PROPS_FILE, 'utf8');
    
    // Ensure 25565 port
    if(key === 'server-port') value = 25565;

    const regex = new RegExp(`^${key}=.*`, 'm');
    if (content.match(regex)) {
        content = content.replace(regex, `${key}=${value}`);
    } else {
        content += `\n${key}=${value}`;
    }
    fs.writeFileSync(PROPS_FILE, content);
}

// Force Port 25565
function ensureNetworkProps() {
    updateProperties('server-port', '25565');
    updateProperties('query.port', '25565');
}

async function downloadServerJar(version) {
    try {
        io.emit('log', `\n[System] Fetching PaperMC ${version}...`);
        const projectRes = await axios.get(`https://api.papermc.io/v2/projects/paper/versions/${version}`);
        const latestBuild = projectRes.data.builds.pop();
        const downloadUrl = `https://api.papermc.io/v2/projects/paper/versions/${version}/builds/${latestBuild}/downloads/paper-${version}-${latestBuild}.jar`;
        
        io.emit('log', `[System] Downloading build #${latestBuild}...`);
        const writer = fs.createWriteStream('server.jar');
        const response = await axios({ url: downloadUrl, method: 'GET', responseType: 'stream' });
        response.data.pipe(writer);
        return new Promise((resolve, reject) => {
            writer.on('finish', resolve);
            writer.on('error', reject);
        });
    } catch (error) {
        io.emit('log', `[System] Download Error: ${error.message}`);
        throw error;
    }
}

// --- EXPRESS ---
app.use(express.static('public'));
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(session({ secret: 'secure-panel-secret', resave: false, saveUninitialized: true }));

function checkAuth(req, res, next) {
    if (req.session.loggedin) next();
    else res.redirect('/login.html');
}

// --- ROUTES ---

// Auth
app.get('/api/check-setup', (req, res) => {
    let users = fs.existsSync(USER_FILE) ? fs.readJsonSync(USER_FILE, { throws: false }) || {} : {};
    res.json({ setupNeeded: Object.keys(users).length === 0 });
});

app.post('/api/auth', (req, res) => {
    const { username, password, action } = req.body;
    let users = fs.existsSync(USER_FILE) ? fs.readJsonSync(USER_FILE, { throws: false }) || {} : {};
    if (action === 'signup') {
        if (Object.keys(users).length > 0) return res.json({ success: false, msg: 'Admin exists.' });
        users[username] = password;
        fs.writeJsonSync(USER_FILE, users);
        req.session.loggedin = true;
        res.json({ success: true });
    } else {
        if (users[username] && users[username] === password) {
            req.session.loggedin = true;
            res.json({ success: true });
        } else res.json({ success: false, msg: 'Invalid credentials' });
    }
});

app.get('/api/logout', (req, res) => { req.session.destroy(); res.redirect('/login.html'); });

// Dashboard
app.get('/', checkAuth, (req, res) => { res.sendFile(path.join(__dirname, 'public/index.html')); });

// Settings
app.get('/api/settings', checkAuth, (req, res) => {
    const cfg = getConfig();
    const props = getProperties();
    res.json({ ...cfg, viewDistance: props.viewDistance });
});

app.post('/api/settings', checkAuth, async (req, res) => {
    const { ram, version, viewDistance } = req.body;
    const oldConfig = getConfig();
    
    saveConfig({ ram, version });
    updateProperties('view-distance', viewDistance);

    if (version !== oldConfig.version) {
        if (serverStatus !== 'offline') stopServer();
        setTimeout(async () => {
            try { await downloadServerJar(version); startServer(); } catch(e){}
        }, 3000);
    }
    res.json({ success: true });
});

// World Management
app.post('/api/world/upload', checkAuth, upload.single('file'), (req, res) => {
    if (serverStatus !== 'offline') return res.status(400).send('Stop server first');
    if (!req.file) return res.status(400).send('No file');
    
    try {
        // Backup Logic could go here
        fs.removeSync('world'); // Remove old world
        const zip = new AdmZip(req.file.path);
        zip.extractAllTo('.', true); // Extract to root (assumes zip contains 'world' folder or level.dat)
        fs.unlinkSync(req.file.path);
        res.redirect('/');
    } catch(e) {
        console.error(e);
        res.status(500).send('Extraction failed');
    }
});

// Plugins
app.get('/api/plugins', checkAuth, (req, res) => {
    fs.readdir(PLUGINS_DIR, (err, files) => {
        if(err) return res.json([]);
        res.json(files.filter(f => f.endsWith('.jar')));
    });
});

app.post('/api/plugins/upload', checkAuth, upload.single('file'), (req, res) => {
    if(req.file) fs.moveSync(req.file.path, path.join(PLUGINS_DIR, req.file.originalname), { overwrite: true });
    res.redirect('/');
});

app.post('/api/plugins/delete', checkAuth, (req, res) => {
    try { fs.removeSync(path.join(PLUGINS_DIR, req.body.filename)); res.json({ success: true }); } catch(e){ res.json({ success: false });}
});

// --- SERVER CONTROL ---
function startServer() {
    if (mcProcess) return;
    const config = getConfig();

    if (!fs.existsSync('server.jar')) {
        io.emit('log', '[System] server.jar missing. Downloading...');
        downloadServerJar(config.version).then(() => startServer()).catch(() => io.emit('log', '[System] Download failed.'));
        return;
    }
    
    ensureNetworkProps();

    serverStatus = 'starting';
    io.emit('status', serverStatus);
    io.emit('log', `\n[System] Starting Server (RAM: ${config.ram}GB)...`);

    const ramArgs = [`-Xmx${config.ram}G`, `-Xms${config.ram}G`];
    mcProcess = spawn('java', [...ramArgs, '-jar', 'server.jar', 'nogui']);

    mcProcess.stdout.on('data', (data) => {
        const line = data.toString();
        logs.push(line);
        if (logs.length > 800) logs.shift();
        io.emit('log', line);
        if (line.includes('Done')) { serverStatus = 'online'; io.emit('status', serverStatus); }
    });

    mcProcess.stderr.on('data', (d) => io.emit('log', d.toString()));

    mcProcess.on('close', (code) => {
        mcProcess = null;
        serverStatus = 'offline';
        io.emit('log', `\n[System] Server Closed (Code ${code})\n`);
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

function sendCommand(cmd) {
    if (mcProcess) mcProcess.stdin.write(cmd + '\n');
}

io.on('connection', (socket) => {
    socket.emit('history', logs.join(''));
    socket.emit('status', serverStatus);
    socket.on('command', (cmd) => {
        if (cmd === '__start__') startServer();
        else if (cmd === '__stop__') stopServer();
        else if (cmd === '__restart__') { stopServer(); setTimeout(startServer, 5000); }
        else sendCommand(cmd);
    });
});

// Init
const cfg = getConfig();
if(!fs.existsSync('server.jar')) downloadServerJar(cfg.version);

// Start Web Panel
const port = process.env.PANEL_PORT || 20000;
server.listen(port, () => console.log(`Dashboard running on port ${port}`));
EOF

# --- 5. CREATE FRONTEND ---
RUN mkdir public

# Login Page (Unchanged style but essential)
RUN cat << 'EOF' > public/login.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Admin Login</title>
<style>
    body{background:#0f172a;color:#f8fafc;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0}
    .card{background:#1e293b;padding:2rem;border-radius:12px;width:320px;text-align:center;border:1px solid #334155}
    input{width:100%;padding:12px;margin-bottom:10px;background:#334155;border:1px solid #475569;color:white;border-radius:6px;box-sizing:border-box}
    button{width:100%;padding:12px;background:#6366f1;color:white;border:none;border-radius:6px;cursor:pointer;font-weight:bold}
</style>
</head>
<body>
<div class="card"><h2 id="title">Login</h2><form id="authForm"><input id="user" placeholder="Username" required><input type="password" id="pass" placeholder="Password" required><button type="submit">Access</button></form></div>
<script>
    fetch('/api/check-setup').then(r=>r.json()).then(d=>{if(d.setupNeeded){document.getElementById('title').innerText='Setup Account';document.getElementById('authForm').dataset.action='signup'}});
    document.getElementById('authForm').onsubmit=async(e)=>{e.preventDefault();const user=document.getElementById('user').value,pass=document.getElementById('pass').value,action=e.target.dataset.action||'login';const res=await fetch('/api/auth',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:user,password:pass,action})});const data=await res.json();if(data.success)location.href='/';else alert(data.msg)}
</script>
</body>
</html>
EOF

# Dashboard Page (Redesigned Compact Grid)
RUN cat << 'EOF' > public/index.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>MC Panel Pro</title>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
<style>
    :root {
        --bg: #0b0e14; --sidebar: #151921; --card: #1e232e; 
        --text: #e2e8f0; --muted: #94a3b8;
        --accent: #6366f1; --danger: #ef4444; --success: #22c55e;
    }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: 'Segoe UI', system-ui, sans-serif; background: var(--bg); color: var(--text); height: 100vh; display: grid; grid-template-columns: 240px 1fr; overflow: hidden; }
    
    /* Sidebar */
    .sidebar { background: var(--sidebar); padding: 20px; display: flex; flex-direction: column; border-right: 1px solid #334155; }
    .brand { font-size: 18px; font-weight: bold; color: var(--accent); margin-bottom: 30px; display: flex; align-items: center; gap: 10px; }
    .nav-btn { padding: 12px; margin-bottom: 5px; border-radius: 8px; cursor: pointer; color: var(--muted); transition: 0.2s; display: flex; align-items: center; gap: 12px; }
    .nav-btn:hover, .nav-btn.active { background: var(--card); color: var(--text); }
    .status-box { margin-top: auto; padding: 15px; background: #00000040; border-radius: 8px; font-size: 14px; }
    .status-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: var(--muted); margin-left: 8px; }
    .s-online { background: var(--success); box-shadow: 0 0 8px var(--success); }
    .s-offline { background: var(--danger); box-shadow: 0 0 8px var(--danger); }

    /* Main Area */
    .main { padding: 20px; overflow-y: auto; display: flex; flex-direction: column; gap: 20px; }
    .header { display: flex; justify-content: space-between; align-items: center; }
    .page { display: none; flex-direction: column; gap: 15px; height: 100%; }
    .page.active { display: flex; }

    /* Components */
    .card { background: var(--card); border: 1px solid #334155; border-radius: 8px; padding: 20px; }
    .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; }
    .btn { padding: 8px 16px; border: none; border-radius: 6px; font-weight: 600; cursor: pointer; color: white; display: inline-flex; align-items: center; gap: 6px; transition: 0.2s; }
    .btn:hover { filter: brightness(1.1); }
    .btn-blue { background: var(--accent); }
    .btn-green { background: var(--success); }
    .btn-red { background: var(--danger); }
    .btn-gray { background: #334155; }
    
    /* Terminal */
    .terminal-wrapper { flex: 1; display: flex; flex-direction: column; background: #0f0f10; border-radius: 8px; border: 1px solid #334155; max-height: 50vh; }
    #terminal { flex: 1; padding: 15px; overflow-y: auto; font-family: monospace; font-size: 13px; color: #cbd5e1; white-space: pre-wrap; }
    .input-bar { display: flex; padding: 10px; border-top: 1px solid #334155; background: #1e232e; }
    #cmdInput { flex: 1; background: transparent; border: none; color: white; outline: none; font-family: monospace; }
    
    /* Forms */
    input[type="text"], input[type="number"], input[type="file"] { width: 100%; padding: 10px; background: #0f172a; border: 1px solid #334155; border-radius: 6px; color: white; }
    .control-row { display: flex; gap: 10px; margin-top: 10px; flex-wrap: wrap; }
    
    /* File List */
    .file-item { display: flex; justify-content: space-between; padding: 10px; border-bottom: 1px solid #334155; font-size: 14px; }
</style>
</head>
<body>

<div class="sidebar">
    <div class="brand"><i class="fas fa-cube"></i> MC Panel Pro</div>
    <div class="nav-btn active" onclick="nav('console')"><i class="fas fa-terminal"></i> Console</div>
    <div class="nav-btn" onclick="nav('players')"><i class="fas fa-users"></i> Players</div>
    <div class="nav-btn" onclick="nav('worlds')"><i class="fas fa-globe"></i> Worlds</div>
    <div class="nav-btn" onclick="nav('plugins')"><i class="fas fa-puzzle-piece"></i> Plugins</div>
    <div class="nav-btn" onclick="nav('settings')"><i class="fas fa-cog"></i> Settings</div>
    <div class="status-box">
        Status: <span id="statusText">...</span> <span id="statusDot" class="status-dot"></span>
        <div style="margin-top:10px; display:flex; gap:5px">
            <button class="btn btn-green" style="flex:1; font-size:12px" onclick="sys('__start__')">Start</button>
            <button class="btn btn-red" style="flex:1; font-size:12px" onclick="sys('__stop__')">Stop</button>
        </div>
    </div>
</div>

<div class="main">
    
    <!-- CONSOLE -->
    <div id="console" class="page active">
        <div class="terminal-wrapper">
            <div id="terminal"></div>
            <div class="input-bar">
                <span style="margin-right:10px; color: var(--accent)">></span>
                <input id="cmdInput" placeholder="Enter command..." autocomplete="off">
            </div>
        </div>
        
        <div class="grid-2">
            <div class="card">
                <h3><i class="fas fa-clock"></i> Quick Time</h3>
                <div class="control-row">
                    <button class="btn btn-gray" onclick="cmd('time set day')">☀ Day</button>
                    <button class="btn btn-gray" onclick="cmd('time set night')">🌙 Night</button>
                    <button class="btn btn-gray" onclick="cmd('weather clear')">☁ Clear</button>
                    <button class="btn btn-gray" onclick="cmd('weather rain')">🌧 Rain</button>
                </div>
            </div>
            <div class="card">
                <h3><i class="fas fa-gamepad"></i> Game Mode</h3>
                <div class="control-row">
                    <button class="btn btn-gray" onclick="cmd('gamemode survival @a')">Survival</button>
                    <button class="btn btn-gray" onclick="cmd('gamemode creative @a')">Creative</button>
                    <button class="btn btn-gray" onclick="cmd('gamemode spectator @a')">Spectator</button>
                </div>
            </div>
        </div>
    </div>

    <!-- PLAYERS -->
    <div id="players" class="page">
        <div class="card">
            <h3>Player Management</h3>
            <div style="display:flex; gap:10px; margin-bottom: 20px;">
                <input id="targetPlayer" placeholder="Player Name">
                <button class="btn btn-blue" onclick="pAction('op')">OP</button>
                <button class="btn btn-blue" onclick="pAction('deop')">DeOP</button>
                <button class="btn btn-red" onclick="pAction('kick')">Kick</button>
                <button class="btn btn-red" onclick="pAction('ban')">Ban</button>
                <button class="btn btn-green" onclick="pAction('pardon')">Unban</button>
            </div>
            <p style="color:var(--muted); font-size:13px">Note: Execute these actions while server is online.</p>
        </div>
    </div>

    <!-- WORLDS -->
    <div id="worlds" class="page">
        <div class="card">
            <h3>Upload World (.zip)</h3>
            <p style="color:#ef4444; font-size:13px; margin-bottom:15px"><i class="fas fa-exclamation-triangle"></i> DANGER: This will delete the current world! Stop the server first.</p>
            <form action="/api/world/upload" method="POST" enctype="multipart/form-data" style="display:flex; gap:10px">
                <input type="file" name="file" accept=".zip" required>
                <button type="submit" class="btn btn-red">Upload & Replace</button>
            </form>
        </div>
    </div>

    <!-- PLUGINS -->
    <div id="plugins" class="page">
        <div class="card">
            <h3>Upload Plugin (.jar)</h3>
            <form action="/api/plugins/upload" method="POST" enctype="multipart/form-data" style="display:flex; gap:10px">
                <input type="file" name="file" accept=".jar" required>
                <button type="submit" class="btn btn-blue">Upload</button>
            </form>
        </div>
        <div class="card">
            <h3>Installed Plugins</h3>
            <div id="pluginList"></div>
        </div>
    </div>

    <!-- SETTINGS -->
    <div id="settings" class="page">
        <div class="card">
            <h3>Server Configuration</h3>
            <div class="control-row" style="flex-direction:column; gap:15px">
                <div>
                    <label>Allocated RAM (GB)</label>
                    <input type="number" id="ramInput">
                </div>
                <div>
                    <label>Minecraft Version (Paper)</label>
                    <input type="text" id="verInput">
                </div>
                <div>
                    <label>Render Distance (Chunks)</label>
                    <input type="number" id="distInput">
                </div>
                <div style="text-align:right">
                    <button class="btn btn-blue" onclick="saveSettings()">Save & Restart</button>
                </div>
            </div>
        </div>
    </div>

</div>

<script src="/socket.io/socket.io.js"></script>
<script>
    const socket = io();
    const term = document.getElementById('terminal');
    let autoScroll = true;

    // Navigation
    function nav(id) {
        document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
        document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
        document.getElementById(id).classList.add('active');
        event.currentTarget.classList.add('active');
        if(id === 'plugins') loadPlugins();
        if(id === 'settings') loadSettings();
    }

    // Command Logic
    function cmd(c) { socket.emit('command', c); }
    function sys(c) { socket.emit('command', c); }
    
    document.getElementById('cmdInput').addEventListener('keydown', (e) => {
        if(e.key === 'Enter' && e.target.value) { cmd(e.target.value); e.target.value = ''; }
    });

    function pAction(act) {
        const p = document.getElementById('targetPlayer').value;
        if(p) cmd(act + ' ' + p); else alert('Enter player name');
    }

    // Socket Events
    socket.on('log', msg => {
        const d = document.createElement('div');
        d.textContent = msg;
        term.appendChild(d);
        if(autoScroll) term.scrollTop = term.scrollHeight;
    });
    
    term.addEventListener('scroll', () => { autoScroll = (term.scrollTop + term.clientHeight >= term.scrollHeight - 20); });

    socket.on('history', h => { term.textContent = h; term.scrollTop = term.scrollHeight; });

    socket.on('status', s => {
        const el = document.getElementById('statusText');
        const dot = document.getElementById('statusDot');
        el.textContent = s.toUpperCase();
        dot.className = 'status-dot ' + (s === 'online' ? 's-online' : s === 'offline' ? 's-offline' : '');
    });

    // Data Loaders
    function loadPlugins() {
        fetch('/api/plugins').then(r=>r.json()).then(d => {
            const l = document.getElementById('pluginList'); l.innerHTML='';
            d.forEach(f => {
                l.innerHTML += `<div class="file-item"><span>${f}</span><span style="color:#ef4444;cursor:pointer" onclick="delPlugin('${f}')"><i class="fas fa-trash"></i></span></div>`
            });
        });
    }

    function delPlugin(f) {
        if(confirm('Delete ' + f + '?')) fetch('/api/plugins/delete', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({filename:f})}).then(loadPlugins);
    }

    function loadSettings() {
        fetch('/api/settings').then(r=>r.json()).then(d => {
            document.getElementById('ramInput').value = d.ram;
            document.getElementById('verInput').value = d.version;
            document.getElementById('distInput').value = d.viewDistance || 10;
        });
    }

    function saveSettings() {
        const data = {
            ram: document.getElementById('ramInput').value,
            version: document.getElementById('verInput').value,
            viewDistance: document.getElementById('distInput').value
        };
        fetch('/api/settings', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)})
        .then(r=>r.json()).then(d => { if(d.success) alert('Saved! Server restarting...'); });
    }
</script>
</body>
</html>
EOF

# --- 6. PORTS ---
EXPOSE 20000 25565

# --- 7. START ---
CMD ["node", "server.js"]
