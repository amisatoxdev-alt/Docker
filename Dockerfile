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

# Initialize Node
RUN npm init -y && \
    npm install express socket.io multer fs-extra body-parser express-session adm-zip axios mime-types

# EULA
RUN echo "eula=true" > eula.txt

# --- 4. BACKEND CODE (server.js) ---
RUN cat << 'EOF' > server.js
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const { spawn, exec } = require('child_process');
const fs = require('fs-extra');
const path = require('path');
const session = require('express-session');
const bodyParser = require('body-parser');
const multer = require('multer');
const AdmZip = require('adm-zip');
const axios = require('axios');
const mime = require('mime-types');

const app = express();
const server = http.createServer(app);
const io = new Server(server);
const upload = multer({ dest: 'temp_uploads/' });

// --- CONSTANTS ---
const USER_FILE = 'users.json';
const CONFIG_FILE = 'server_config.json';
const PROPS_FILE = 'server.properties';
const PLUGINS_DIR = 'plugins';

// Ensure Directories
fs.ensureDirSync(PLUGINS_DIR);
fs.ensureDirSync('views'); 
fs.ensureDirSync('public');

// --- CONFIG DEFAULTS ---
const DEFAULT_CONFIG = { ram: "4", version: "1.20.4" };

// --- HELPERS ---
function getConfig() {
    if (!fs.existsSync(CONFIG_FILE)) fs.writeJsonSync(CONFIG_FILE, DEFAULT_CONFIG);
    return fs.readJsonSync(CONFIG_FILE);
}

function saveConfig(cfg) {
    fs.writeJsonSync(CONFIG_FILE, cfg);
}

function getUsers() {
    if (!fs.existsSync(USER_FILE)) return {};
    return fs.readJsonSync(USER_FILE, { throws: false }) || {};
}

function saveUsers(users) {
    fs.writeJsonSync(USER_FILE, users);
}

function updateProperties(updates) {
    let content = "";
    if (fs.existsSync(PROPS_FILE)) content = fs.readFileSync(PROPS_FILE, 'utf8');
    updates['server-port'] = 25565; // Force port
    for (const [key, value] of Object.entries(updates)) {
        const regex = new RegExp(`^${key}=.*`, 'm');
        if (content.match(regex)) content = content.replace(regex, `${key}=${value}`);
        else content += `\n${key}=${value}`;
    }
    fs.writeFileSync(PROPS_FILE, content);
}

function getProp(key, def) {
    if (!fs.existsSync(PROPS_FILE)) return def;
    const content = fs.readFileSync(PROPS_FILE, 'utf8');
    const match = content.match(new RegExp(`${key}=(.*)`));
    return match ? match[1].trim() : def;
}

// --- SERVER PROCESS ---
let mcProcess = null;
let logs = [];
let serverStatus = 'offline';

async function downloadServerJar(version) {
    try {
        io.emit('log', `\n[System] Fetching PaperMC ${version}...`);
        const pRes = await axios.get(`https://api.papermc.io/v2/projects/paper/versions/${version}`);
        const build = pRes.data.builds.pop();
        const url = `https://api.papermc.io/v2/projects/paper/versions/${version}/builds/${build}/downloads/paper-${version}-${build}.jar`;
        
        io.emit('log', `[System] Downloading build #${build}...`);
        const writer = fs.createWriteStream('server.jar');
        const response = await axios({ url, method: 'GET', responseType: 'stream' });
        response.data.pipe(writer);
        return new Promise((resolve, reject) => {
            writer.on('finish', resolve);
            writer.on('error', reject);
        });
    } catch (e) { throw e; }
}

function startServer() {
    if (mcProcess) return;
    const config = getConfig();
    if (!fs.existsSync('server.jar')) {
        io.emit('log', '[System] Jar missing. Downloading...');
        downloadServerJar(config.version).then(startServer).catch(e => io.emit('log', '[Error] ' + e.message));
        return;
    }
    updateProperties({});
    serverStatus = 'starting';
    io.emit('status', serverStatus);
    io.emit('log', `\n[System] Starting Server (${config.ram}GB RAM)...`);

    mcProcess = spawn('java', [`-Xmx${config.ram}G`, `-Xms${config.ram}G`, '-jar', 'server.jar', 'nogui']);
    
    mcProcess.stdout.on('data', d => {
        const l = d.toString();
        logs.push(l); if(logs.length>800) logs.shift();
        io.emit('log', l);
        if(l.includes('Done')) { serverStatus='online'; io.emit('status', serverStatus); }
    });
    mcProcess.stderr.on('data', d => io.emit('log', d.toString()));
    mcProcess.on('close', c => {
        mcProcess=null; serverStatus='offline'; 
        io.emit('status', serverStatus); io.emit('log', `\n[System] Stopped (Code ${c})`); 
    });
}

function stopServer() {
    if (mcProcess) {
        serverStatus='stopping'; io.emit('status', serverStatus);
        mcProcess.stdin.write('stop\n');
    }
}

// --- MIDDLEWARE ---
app.use(express.static('public'));
app.use(bodyParser.json({limit:'500mb'}));
app.use(bodyParser.urlencoded({limit:'500mb', extended:true}));
app.use(session({secret:'glass-secret', resave:false, saveUninitialized:false}));

function checkAuth(req, res, next) {
    if (req.session.loggedin) next();
    else res.redirect('/login.html');
}

function requireAdmin(req, res, next) {
    if (req.session.role === 'admin') next();
    else res.status(403).json({success:false, msg:'Access Denied: Admins Only'});
}

// --- API ROUTES ---

// Auth
app.get('/', checkAuth, (req, res) => res.sendFile(path.join(__dirname, 'views', 'dashboard.html')));

app.get('/api/check-setup', (req, res) => {
    const users = getUsers();
    res.json({ setupNeeded: Object.keys(users).length === 0 });
});

app.post('/api/auth', (req, res) => {
    const { username, password, action } = req.body;
    let users = getUsers();

    if (action === 'signup') {
        if (Object.keys(users).length > 0) return res.json({success:false, msg:'Admin already exists'});
        users[username] = { password, role: 'admin' }; // First user is always admin
        saveUsers(users);
        req.session.loggedin = true;
        req.session.username = username;
        req.session.role = 'admin';
        req.session.save(() => res.json({success:true}));
    } else {
        if (users[username] && users[username].password === password) {
            req.session.loggedin = true;
            req.session.username = username;
            req.session.role = users[username].role || 'user';
            req.session.save(() => res.json({success:true}));
        } else res.json({success:false, msg:'Invalid credentials'});
    }
});

app.get('/api/user-info', checkAuth, (req, res) => {
    res.json({ username: req.session.username, role: req.session.role });
});

app.get('/api/logout', (req, res) => { req.session.destroy(); res.redirect('/login.html'); });

// User Management (Admin Only)
app.post('/api/users/create', checkAuth, requireAdmin, (req, res) => {
    const { username, password, role } = req.body;
    let users = getUsers();
    if(users[username]) return res.json({success:false, msg:'User exists'});
    users[username] = { password, role };
    saveUsers(users);
    res.json({success:true});
});

app.get('/api/users/list', checkAuth, requireAdmin, (req, res) => {
    const users = getUsers();
    const list = Object.keys(users).map(u => ({ username: u, role: users[u].role }));
    res.json(list);
});

// Settings (Admin Only for Write)
app.get('/api/settings', checkAuth, (req, res) => {
    const cfg = getConfig();
    res.json({ ram: cfg.ram, version: cfg.version, viewDistance: getProp('view-distance', '10'), onlineMode: getProp('online-mode', 'true') });
});

app.post('/api/settings', checkAuth, requireAdmin, async (req, res) => {
    try {
        const { ram, version, viewDistance, onlineMode } = req.body;
        const oldConfig = getConfig();
        saveConfig({ ram, version });
        updateProperties({ 'view-distance': viewDistance, 'online-mode': onlineMode });
        res.json({success:true});
        
        if (version !== oldConfig.version) {
            if(serverStatus !== 'offline') stopServer();
            setTimeout(async () => {
                try {
                    if(fs.existsSync('server.jar')) fs.unlinkSync('server.jar');
                    await downloadServerJar(version);
                    startServer();
                } catch(e) { console.error(e); }
            }, 5000);
        }
    } catch(e) { res.status(500).json({success:false, msg:e.message}); }
});

// File Manager
app.get('/api/files', checkAuth, (req, res) => {
    const reqPath = req.query.path || '';
    const safePath = path.join(__dirname, reqPath);
    
    // Security check
    if (!safePath.startsWith(__dirname)) return res.status(403).send('Access Denied');

    fs.readdir(safePath, { withFileTypes: true }, (err, files) => {
        if (err) return res.json([]);
        const result = files.map(f => ({
            name: f.name,
            isDir: f.isDirectory(),
            size: f.isDirectory() ? '-' : (fs.statSync(path.join(safePath, f.name)).size / 1024).toFixed(1) + ' KB'
        }));
        res.json(result);
    });
});

app.post('/api/files/upload', checkAuth, upload.single('file'), (req, res) => {
    const targetPath = req.body.path || '';
    const safePath = path.join(__dirname, targetPath, req.file.originalname);
    if (!safePath.startsWith(__dirname)) return res.status(403).send('Access Denied');
    
    fs.moveSync(req.file.path, safePath, { overwrite: true });
    res.redirect('/'); // Reloads handled by frontend
});

app.post('/api/files/delete', checkAuth, requireAdmin, (req, res) => {
    const target = req.body.path;
    const safePath = path.join(__dirname, target);
    if (!safePath.startsWith(__dirname) || target === '') return res.status(403).send('Denied');
    fs.removeSync(safePath);
    res.json({success:true});
});

app.get('/api/files/download', checkAuth, (req, res) => {
    const target = req.query.path;
    const safePath = path.join(__dirname, target);
    if (!safePath.startsWith(__dirname)) return res.status(403).send('Denied');
    res.download(safePath);
});

// World Management
app.get('/api/world/download', checkAuth, (req, res) => {
    if (!fs.existsSync('world')) return res.status(404).send('No world folder found');
    const archive = new AdmZip();
    archive.addLocalFolder('world', 'world');
    const buffer = archive.toBuffer();
    res.set('Content-Type', 'application/zip');
    res.set('Content-Disposition', 'attachment; filename=world_backup.zip');
    res.send(buffer);
});

app.post('/api/world/upload', checkAuth, requireAdmin, upload.single('file'), (req, res) => {
    if (serverStatus !== 'offline') return res.status(400).json({success:false, msg:'Stop server first'});
    try {
        if (fs.existsSync('world')) fs.rmSync('world', {recursive:true, force:true});
        const zip = new AdmZip(req.file.path);
        zip.extractAllTo('.', true);
        fs.unlinkSync(req.file.path);
        res.json({success:true});
    } catch(e) { res.status(500).json({success:false, msg:e.message}); }
});

// Socket
io.on('connection', s => {
    s.emit('history', logs.join(''));
    s.emit('status', serverStatus);
    s.on('command', c => {
        if(c==='__start__') startServer();
        else if(c==='__stop__') stopServer();
        else if(c==='__restart__') { stopServer(); setTimeout(startServer, 5000); }
        else if(mcProcess) mcProcess.stdin.write(c+'\n');
    });
});

const port = process.env.PANEL_PORT || 20000;
server.listen(port, () => console.log(`Panel on ${port}`));
EOF

# --- 5. FRONTEND FILES ---
RUN mkdir -p public views

# LOGIN PAGE
RUN cat << 'EOF' > public/login.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pro Login</title>
<style>
    body { background: #000; color: #fff; font-family: 'Segoe UI', sans-serif; height: 100vh; display: flex; align-items: center; justify-content: center; overflow: hidden; margin: 0; }
    .bg-orb { position: absolute; width: 300px; height: 300px; border-radius: 50%; filter: blur(80px); opacity: 0.6; z-index: -1; animation: float 6s infinite ease-in-out; }
    .orb-1 { background: #6366f1; top: 20%; left: 20%; }
    .orb-2 { background: #ec4899; bottom: 20%; right: 20%; animation-delay: 3s; }
    @keyframes float { 0%, 100% { transform: translateY(0); } 50% { transform: translateY(-20px); } }
    
    .card { background: rgba(255, 255, 255, 0.05); backdrop-filter: blur(20px); border: 1px solid rgba(255,255,255,0.1); padding: 40px; border-radius: 20px; width: 320px; text-align: center; box-shadow: 0 20px 50px rgba(0,0,0,0.5); }
    h2 { margin-bottom: 20px; font-weight: 300; letter-spacing: 2px; }
    input { width: 100%; padding: 15px; margin-bottom: 15px; background: rgba(0,0,0,0.3); border: 1px solid rgba(255,255,255,0.2); border-radius: 10px; color: white; box-sizing: border-box; outline: none; transition: 0.3s; }
    input:focus { border-color: #6366f1; background: rgba(0,0,0,0.5); }
    button { width: 100%; padding: 15px; background: linear-gradient(45deg, #6366f1, #8b5cf6); color: white; border: none; border-radius: 10px; font-weight: bold; cursor: pointer; transition: 0.3s; letter-spacing: 1px; }
    button:hover { transform: translateY(-2px); box-shadow: 0 10px 20px rgba(99, 102, 241, 0.4); }
</style>
</head>
<body>
<div class="bg-orb orb-1"></div>
<div class="bg-orb orb-2"></div>
<div class="card">
    <h2 id="title">LOGIN</h2>
    <form id="authForm">
        <input id="user" placeholder="Username" required>
        <input type="password" id="pass" placeholder="Password" required>
        <button type="submit">ENTER SYSTEM</button>
    </form>
</div>
<script>
    fetch('/api/check-setup').then(r=>r.json()).then(d=>{if(d.setupNeeded){document.getElementById('title').innerText='SETUP ADMIN';document.getElementById('authForm').dataset.action='signup'}});
    document.getElementById('authForm').onsubmit=async(e)=>{
        e.preventDefault();
        const user=document.getElementById('user').value;
        const pass=document.getElementById('pass').value;
        const action=e.target.dataset.action||'login';
        try {
            const res=await fetch('/api/auth',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:user,password:pass,action})});
            const data=await res.json();
            if(data.success) window.location.href='/'; else alert(data.msg);
        } catch(err){ alert('Network Error'); }
    }
</script>
</body>
</html>
EOF

# DASHBOARD PAGE
RUN cat << 'EOF' > views/dashboard.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>MC Glass Panel</title>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
<style>
    /* CSS VARIABLES */
    :root { --glass: rgba(20, 20, 25, 0.7); --border: rgba(255, 255, 255, 0.08); --accent: #6366f1; --text: #e2e8f0; }
    body { margin: 0; font-family: 'Segoe UI', sans-serif; background: #050505; color: var(--text); height: 100vh; display: flex; overflow: hidden; }
    
    /* ANIMATED BG */
    .bg-mesh { position: absolute; top:0; left:0; width:100%; height:100%; z-index:-2; background: radial-gradient(circle at 10% 20%, #1a1a2e 0%, #000 90%); }
    .intro-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: #000; z-index: 9999; display: flex; justify-content: center; align-items: center; animation: fadeOut 1s ease-in-out 1.5s forwards; }
    .intro-logo { font-size: 40px; font-weight: bold; background: linear-gradient(45deg, #6366f1, #ec4899); -webkit-background-clip: text; color: transparent; animation: zoomIn 1s ease-out; }
    @keyframes fadeOut { to { opacity: 0; visibility: hidden; } }
    @keyframes zoomIn { from { transform: scale(0.8); opacity: 0; } to { transform: scale(1); opacity: 1; } }

    /* LAYOUT */
    .sidebar { width: 250px; background: var(--glass); backdrop-filter: blur(20px); border-right: 1px solid var(--border); display: flex; flex-direction: column; padding: 20px; z-index: 10; }
    .main { flex: 1; padding: 30px; overflow-y: auto; position: relative; }
    
    .brand { font-size: 20px; font-weight: 700; color: #fff; margin-bottom: 40px; display: flex; align-items: center; gap: 10px; }
    .brand i { color: var(--accent); }
    
    .nav-item { padding: 12px 15px; margin: 5px 0; border-radius: 12px; cursor: pointer; color: #aaa; transition: 0.3s; display: flex; align-items: center; gap: 12px; font-weight: 500; }
    .nav-item:hover, .nav-item.active { background: rgba(99, 102, 241, 0.15); color: #fff; border: 1px solid rgba(99, 102, 241, 0.2); }
    
    .status-panel { margin-top: auto; padding: 15px; background: rgba(0,0,0,0.3); border-radius: 12px; border: 1px solid var(--border); }
    .status-badge { display: inline-block; padding: 4px 8px; border-radius: 4px; font-size: 11px; font-weight: bold; text-transform: uppercase; }
    .st-online { background: rgba(34, 197, 94, 0.2); color: #4ade80; }
    .st-offline { background: rgba(239, 68, 68, 0.2); color: #f87171; }

    /* CARDS & INPUTS */
    .page { display: none; animation: slideUp 0.4s ease-out; }
    .page.active { display: block; }
    @keyframes slideUp { from { transform: translateY(20px); opacity: 0; } to { transform: translateY(0); opacity: 1; } }
    
    .glass-card { background: var(--glass); backdrop-filter: blur(20px); border: 1px solid var(--border); border-radius: 16px; padding: 25px; margin-bottom: 20px; }
    h2 { margin-top: 0; font-weight: 600; font-size: 18px; border-bottom: 1px solid var(--border); padding-bottom: 15px; margin-bottom: 20px; color: #fff; }
    
    .btn { padding: 10px 20px; border-radius: 8px; border: none; font-weight: 600; cursor: pointer; transition: 0.2s; color: white; display: inline-flex; align-items: center; gap: 8px; }
    .btn:hover { transform: translateY(-2px); filter: brightness(1.2); }
    .btn-primary { background: var(--accent); }
    .btn-danger { background: #ef4444; }
    .btn-success { background: #22c55e; }
    .btn-dark { background: #333; border: 1px solid #444; }

    input, select { width: 100%; padding: 12px; background: rgba(0,0,0,0.4); border: 1px solid var(--border); border-radius: 8px; color: white; margin-bottom: 10px; }
    
    /* TERMINAL */
    .terminal { background: #0a0a0c; border-radius: 12px; height: 50vh; overflow-y: auto; padding: 15px; font-family: monospace; font-size: 13px; border: 1px solid var(--border); margin-bottom: 15px; }
    .cmd-input { width: 100%; background: transparent; border: none; border-top: 1px solid var(--border); padding: 15px; color: white; outline: none; font-family: monospace; }
    
    /* FILE MANAGER */
    .file-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 10px; }
    .file-box { background: rgba(255,255,255,0.03); padding: 15px; border-radius: 8px; text-align: center; cursor: pointer; transition: 0.2s; border: 1px solid transparent; }
    .file-box:hover { background: rgba(255,255,255,0.08); border-color: var(--accent); }
    .file-icon { font-size: 30px; margin-bottom: 10px; color: var(--accent); }
    .file-name { font-size: 12px; word-break: break-all; }
    .folder-icon { color: #facc15; }
    
    /* PROGRESS BAR */
    .progress-wrap { background: #333; height: 10px; border-radius: 5px; margin-top: 10px; display: none; overflow:hidden; }
    .progress-fill { height: 100%; background: var(--success); width: 0%; transition: width 0.2s; }
</style>
</head>
<body>

<!-- INTRO ANIMATION -->
<div class="intro-overlay"><div class="intro-logo">MC PANEL PRO</div></div>
<div class="bg-mesh"></div>

<div class="sidebar">
    <div class="brand"><i class="fas fa-cube"></i> PANEL PRO</div>
    <div class="nav-item active" onclick="nav('console')"><i class="fas fa-terminal"></i> Console</div>
    <div class="nav-item" onclick="nav('files')"><i class="fas fa-folder"></i> Files</div>
    <div class="nav-item" onclick="nav('world')"><i class="fas fa-globe"></i> World</div>
    <div class="nav-item" onclick="nav('settings')"><i class="fas fa-sliders"></i> Settings</div>
    <div class="nav-item admin-only" onclick="nav('users')"><i class="fas fa-users"></i> Users</div>
    <div class="nav-item" onclick="location.href='/api/logout'"><i class="fas fa-sign-out-alt"></i> Logout</div>
    
    <div class="status-panel">
        <div style="display:flex; justify-content:space-between; margin-bottom:10px">
            <span style="font-size:12px; color:#aaa">STATUS</span>
            <span id="statusBadge" class="status-badge st-offline">OFFLINE</span>
        </div>
        <div style="display:flex; gap:5px">
            <button class="btn btn-success" style="flex:1; padding:8px; font-size:12px" onclick="sock.emit('command', '__start__')">ON</button>
            <button class="btn btn-danger" style="flex:1; padding:8px; font-size:12px" onclick="sock.emit('command', '__stop__')">OFF</button>
        </div>
    </div>
</div>

<div class="main">
    
    <!-- CONSOLE -->
    <div id="console" class="page active">
        <div class="glass-card">
            <div id="term" class="terminal"></div>
            <input class="cmd-input" id="cmd" placeholder="> Enter command..." autocomplete="off">
        </div>
    </div>

    <!-- FILE MANAGER -->
    <div id="files" class="page">
        <div class="glass-card">
            <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:15px">
                <h2>File Manager</h2>
                <div style="display:flex; gap:10px">
                    <button class="btn btn-dark" onclick="loadFile('.')"><i class="fas fa-home"></i></button>
                    <button class="btn btn-dark" onclick="goUp()"><i class="fas fa-arrow-up"></i></button>
                    <button class="btn btn-primary" onclick="document.getElementById('fUpload').click()">Upload</button>
                    <input type="file" id="fUpload" hidden onchange="uploadFile(this)">
                </div>
            </div>
            <div style="margin-bottom:10px; color:#aaa; font-size:13px" id="currentPath">/app</div>
            <div id="fileGrid" class="file-grid"></div>
        </div>
    </div>

    <!-- WORLD MANAGER -->
    <div id="world" class="page">
        <div class="glass-card">
            <h2>World Management</h2>
            <div style="display:flex; gap:20px; flex-wrap:wrap">
                <div style="flex:1; min-width:250px">
                    <h3><i class="fas fa-download"></i> Download World</h3>
                    <p style="color:#aaa; font-size:13px">Download the current 'world' folder as a ZIP file.</p>
                    <button class="btn btn-primary" onclick="location.href='/api/world/download'">Download Zip</button>
                </div>
                <div style="flex:1; min-width:250px">
                    <h3><i class="fas fa-upload"></i> Upload World</h3>
                    <p style="color:#ef4444; font-size:13px">Warning: This deletes the current world!</p>
                    <input type="file" id="worldZip" accept=".zip">
                    <button class="btn btn-danger" onclick="uploadWorldZip()">Upload & Replace</button>
                    <div id="wProg" class="progress-wrap"><div id="wBar" class="progress-fill"></div></div>
                </div>
            </div>
        </div>
    </div>

    <!-- USERS (ADMIN ONLY) -->
    <div id="users" class="page">
        <div class="glass-card">
            <h2>User Management</h2>
            <div style="display:flex; gap:10px; margin-bottom:20px">
                <input id="newUser" placeholder="Username">
                <input id="newPass" placeholder="Password">
                <select id="newRole"><option value="user">User</option><option value="admin">Admin</option></select>
                <button class="btn btn-success" onclick="createUser()">Add</button>
            </div>
            <div id="userList" style="background:rgba(0,0,0,0.3); border-radius:8px; padding:10px"></div>
        </div>
    </div>

    <!-- SETTINGS -->
    <div id="settings" class="page">
        <div class="glass-card">
            <h2>Server Settings</h2>
            <div id="settingsMsg" style="color:#facc15; font-size:13px; margin-bottom:10px"></div>
            
            <label>RAM Allocation (GB) <span class="badge admin-only">Admin</span></label>
            <input type="number" id="ram" class="admin-input">
            
            <label>PaperMC Version <span class="badge admin-only">Admin</span></label>
            <input type="text" id="ver" class="admin-input">
            
            <label>Render Distance</label>
            <input type="number" id="dist" class="admin-input">
            
            <label>Online Mode</label>
            <select id="online" class="admin-input">
                <option value="true">True (Premium)</option>
                <option value="false">False (Cracked)</option>
            </select>
            
            <div style="text-align:right; margin-top:15px">
                <button id="saveBtn" class="btn btn-primary admin-input" onclick="saveSettings()">Save & Apply</button>
            </div>
        </div>
    </div>

</div>

<script src="/socket.io/socket.io.js"></script>
<script>
    const sock = io();
    let currPath = '';
    let isAdmin = false;

    // --- INIT ---
    fetch('/api/user-info').then(r=>r.json()).then(u => {
        isAdmin = (u.role === 'admin');
        if(!isAdmin) {
            document.querySelectorAll('.admin-only').forEach(e => e.style.display='none');
            document.querySelectorAll('.admin-input').forEach(e => e.disabled = true);
            document.getElementById('settingsMsg').innerText = 'Read-Only Mode (User Role)';
        }
        if(isAdmin) loadUsers();
    });

    // --- NAV ---
    function nav(id) {
        document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
        document.querySelectorAll('.nav-item').forEach(i => i.classList.remove('active'));
        document.getElementById(id).classList.add('active');
        event.currentTarget.classList.add('active');
        if(id==='files') loadFile('');
        if(id==='settings') loadSettings();
    }

    // --- CONSOLE ---
    sock.on('log', d => {
        const t = document.getElementById('term');
        const l = document.createElement('div'); l.textContent=d;
        t.appendChild(l); t.scrollTop=t.scrollHeight;
    });
    sock.on('status', s => {
        const b = document.getElementById('statusBadge');
        b.className = 'status-badge ' + (s==='online'?'st-online':'st-offline');
        b.textContent = s.toUpperCase();
    });
    document.getElementById('cmd').addEventListener('keydown', e => {
        if(e.key==='Enter' && e.target.value) { sock.emit('command', e.target.value); e.target.value=''; }
    });

    // --- FILE MANAGER ---
    function loadFile(path) {
        currPath = path;
        document.getElementById('currentPath').innerText = '/app/' + path;
        fetch('/api/files?path='+path).then(r=>r.json()).then(files => {
            const g = document.getElementById('fileGrid'); g.innerHTML='';
            files.forEach(f => {
                const icon = f.isDir ? 'fa-folder folder-icon' : 'fa-file-alt';
                const el = document.createElement('div');
                el.className = 'file-box';
                el.innerHTML = `<i class="fas ${icon} file-icon"></i><div class="file-name">${f.name}</div><div style="font-size:10px; color:#666">${f.size}</div>`;
                el.onclick = () => {
                    if(f.isDir) loadFile(path ? path+'/'+f.name : f.name);
                    else if(confirm('Download '+f.name+'?')) window.open(`/api/files/download?path=${path ? path+'/'+f.name : f.name}`);
                };
                if(isAdmin) {
                    el.oncontextmenu = (e) => {
                        e.preventDefault();
                        if(confirm('Delete '+f.name+'?')) fetch('/api/files/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:path?path+'/'+f.name:f.name})}).then(()=>loadFile(currPath));
                    }
                }
                g.appendChild(el);
            });
        });
    }
    function goUp() {
        const p = currPath.split('/'); p.pop(); loadFile(p.join('/'));
    }
    function uploadFile(input) {
        if(!input.files[0]) return;
        const fd = new FormData(); fd.append('file', input.files[0]); fd.append('path', currPath);
        fetch('/api/files/upload', {method:'POST', body:fd}).then(()=>loadFile(currPath));
    }

    // --- SETTINGS ---
    function loadSettings() {
        fetch('/api/settings').then(r=>r.json()).then(d => {
            document.getElementById('ram').value=d.ram;
            document.getElementById('ver').value=d.version;
            document.getElementById('dist').value=d.viewDistance;
            document.getElementById('online').value=d.onlineMode;
        });
    }
    function saveSettings() {
        if(!isAdmin) return;
        const d = { ram:document.getElementById('ram').value, version:document.getElementById('ver').value, viewDistance:document.getElementById('dist').value, onlineMode:document.getElementById('online').value };
        fetch('/api/settings', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)}).then(r=>r.json()).then(j=>{if(j.success)alert('Saved!');});
    }

    // --- WORLD ---
    function uploadWorldZip() {
        if(!isAdmin) return alert('Admins only');
        const f = document.getElementById('worldZip').files[0];
        if(!f) return alert('Select file');
        const fd = new FormData(); fd.append('file', f);
        const xhr = new XMLHttpRequest();
        xhr.upload.onprogress = e => { 
            document.getElementById('wProg').style.display='block';
            document.getElementById('wBar').style.width = (e.loaded/e.total)*100 + '%';
        };
        xhr.onload = () => alert(xhr.status===200 ? 'Success' : 'Fail');
        xhr.open('POST', '/api/world/upload'); xhr.send(fd);
    }

    // --- USERS ---
    function loadUsers() {
        fetch('/api/users/list').then(r=>r.json()).then(list => {
            const div = document.getElementById('userList'); div.innerHTML='';
            list.forEach(u => div.innerHTML += `<div style="border-bottom:1px solid #444; padding:5px; display:flex; justify-content:space-between"><span>${u.username}</span><span style="color:${u.role==='admin'?'#facc15':'#aaa'}">${u.role}</span></div>`);
        });
    }
    function createUser() {
        const u = document.getElementById('newUser').value;
        const p = document.getElementById('newPass').value;
        const r = document.getElementById('newRole').value;
        fetch('/api/users/create', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p,role:r})}).then(r=>r.json()).then(d=>{
            if(d.success) { loadUsers(); alert('User Added'); } else alert(d.msg);
        });
    }
</script>
</body>
</html>
EOF

# --- 6. EXPOSE PORTS & VOLUMES ---
EXPOSE 20000 25565
# OPTIONAL: Define a volume for the whole app to persist data
# VOLUME ["/app"]

# --- 7. START ---
CMD ["node", "server.js"]
