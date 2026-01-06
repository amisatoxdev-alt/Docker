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

# Initialize Node & Install Packages
RUN npm init -y && \
    npm install express socket.io multer fs-extra body-parser express-session adm-zip axios mime-types

# Accept EULA
RUN echo "eula=true" > eula.txt

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

// --- 50GB UPLOAD SUPPORT ---
server.timeout = 0; 
const upload = multer({ dest: 'temp_uploads/', limits: { fileSize: 50 * 1024 * 1024 * 1024 } });

app.use(bodyParser.json({ limit: '50gb' }));
app.use(bodyParser.urlencoded({ limit: '50gb', extended: true }));
app.use(session({
    secret: 'mc-panel-ultimate-key', 
    resave: false, 
    saveUninitialized: false,
    cookie: { maxAge: 24 * 60 * 60 * 1000 }
}));
app.use(express.static('public'));

// --- CONSTANTS ---
const USER_FILE = 'users.json';
const CONFIG_FILE = 'server_config.json';
const PROPS_FILE = 'server.properties';
const PLUGINS_DIR = 'plugins';

fs.ensureDirSync(PLUGINS_DIR);
fs.ensureDirSync('views'); 
fs.ensureDirSync('public');

// --- HELPERS ---
function getConfig() {
    if (!fs.existsSync(CONFIG_FILE)) fs.writeJsonSync(CONFIG_FILE, { ram: "4", version: "1.20.4" });
    return fs.readJsonSync(CONFIG_FILE);
}
function saveConfig(cfg) { fs.writeJsonSync(CONFIG_FILE, cfg); }

function getUsers() { return fs.readJsonSync(USER_FILE, { throws: false }) || {}; }
function saveUsers(users) { fs.writeJsonSync(USER_FILE, users); }

function updateProperties(updates) {
    let content = "";
    if (fs.existsSync(PROPS_FILE)) content = fs.readFileSync(PROPS_FILE, 'utf8');
    updates['server-port'] = 25565; 
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

// --- SERVER LOGIC ---
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
function checkAuth(req, res, next) {
    if (req.session.loggedin) next();
    else res.redirect('/login.html');
}

function requireAdmin(req, res, next) {
    if (req.session.role === 'admin') next();
    else res.status(403).json({success:false, msg:'Admins Only'});
}

// --- API ROUTES ---

app.get('/', checkAuth, (req, res) => res.sendFile(path.join(__dirname, 'views', 'dashboard.html')));
app.get('/api/check-setup', (req, res) => res.json({ setupNeeded: Object.keys(getUsers()).length === 0 }));

// AUTH & RESET
app.post('/api/auth', (req, res) => {
    const { username, password, action } = req.body;
    let users = getUsers();
    if (action === 'signup') {
        if (Object.keys(users).length > 0) return res.json({success:false, msg:'Admin exists'});
        users[username] = { password, role: 'admin' };
        saveUsers(users);
        req.session.loggedin=true; req.session.username=username; req.session.role='admin';
        req.session.save(() => res.json({success:true}));
    } else {
        if (users[username] && users[username].password === password) {
            req.session.loggedin=true; req.session.username=username;
            req.session.role = users[username].role || 'user';
            req.session.save(() => res.json({success:true}));
        } else res.json({success:false, msg:'Invalid credentials'});
    }
});

// PASSWORD RESET ROUTE
app.post('/api/auth/reset', (req, res) => {
    const { code, newPassword } = req.body;
    if (code === 'yuhansato0009') {
        let users = getUsers();
        // Find existing admin or create default
        let adminUser = Object.keys(users).find(u => users[u].role === 'admin') || 'admin';
        users[adminUser] = { password: newPassword, role: 'admin' };
        saveUsers(users);
        res.json({ success: true, msg: 'Admin password reset successfully.' });
    } else {
        res.json({ success: false, msg: 'Invalid Backup Code.' });
    }
});

app.get('/api/user-info', checkAuth, (req, res) => res.json({ username: req.session.username, role: req.session.role }));
app.get('/api/logout', (req, res) => { req.session.destroy(); res.redirect('/login.html'); });

// User Management
app.post('/api/users/create', checkAuth, requireAdmin, (req, res) => {
    const { username, password, role } = req.body;
    let users = getUsers();
    if(users[username]) return res.json({success:false, msg:'User exists'});
    users[username] = { password, role };
    saveUsers(users);
    res.json({success:true});
});
app.post('/api/users/delete', checkAuth, requireAdmin, (req, res) => {
    const { username } = req.body;
    let users = getUsers();
    if(username === req.session.username) return res.json({success:false, msg:"Cannot delete yourself"});
    delete users[username];
    saveUsers(users);
    res.json({success:true});
});
app.get('/api/users/list', checkAuth, requireAdmin, (req, res) => {
    const users = getUsers();
    res.json(Object.keys(users).map(u => ({ username: u, role: users[u].role })));
});

// Settings
app.get('/api/settings', checkAuth, (req, res) => {
    const cfg = getConfig();
    res.json({ ram: cfg.ram, version: cfg.version, viewDistance: getProp('view-distance', '10'), onlineMode: getProp('online-mode', 'true') });
});
app.post('/api/settings', checkAuth, async (req, res) => {
    try {
        const { ram, version, viewDistance, onlineMode } = req.body;
        const oldConfig = getConfig();
        if (req.session.role !== 'admin' && ram !== oldConfig.ram) return res.status(403).json({success:false, msg:'Only Admins can change RAM.'});
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

// Files (Modified for Multi-upload)
app.get('/api/files', checkAuth, (req, res) => {
    const safePath = path.join(__dirname, req.query.path || '');
    if (!safePath.startsWith(__dirname)) return res.status(403).send('Denied');
    fs.readdir(safePath, { withFileTypes: true }, (err, files) => {
        if (err) return res.json([]);
        const result = files.map(f => {
            const stats = fs.statSync(path.join(safePath, f.name));
            return {
                name: f.name,
                isDir: f.isDirectory(),
                size: f.isDirectory() ? '--' : (stats.size / 1024).toFixed(1) + ' KB',
                date: stats.mtime.toLocaleDateString()
            };
        });
        res.json(result);
    });
});

// Handle Multiple Files (Folders)
app.post('/api/files/upload', checkAuth, upload.array('files'), (req, res) => {
    const basePath = path.join(__dirname, req.body.path || '');
    if (!basePath.startsWith(__dirname)) return res.status(403).send('Denied');
    
    if (req.files) {
        req.files.forEach(f => {
            fs.moveSync(f.path, path.join(basePath, f.originalname), { overwrite: true });
        });
    }
    // Return JSON instead of redirect for AJAX
    res.json({success: true});
});

app.post('/api/files/delete', checkAuth, (req, res) => {
    const safePath = path.join(__dirname, req.body.path);
    if (!safePath.startsWith(__dirname)) return res.status(403).send('Denied');
    fs.removeSync(safePath);
    res.json({success:true});
});
app.get('/api/files/download', checkAuth, (req, res) => {
    const safePath = path.join(__dirname, req.query.path);
    if (!safePath.startsWith(__dirname)) return res.status(403).send('Denied');
    res.download(safePath);
});

// World Manager
app.get('/api/world/download', checkAuth, (req, res) => {
    if (!fs.existsSync('world')) return res.status(404).send('No world found');
    const zip = new AdmZip(); zip.addLocalFolder('world', 'world');
    res.set('Content-Type','application/zip').set('Content-Disposition','attachment; filename=world.zip').send(zip.toBuffer());
});
app.post('/api/world/upload', checkAuth, upload.single('file'), (req, res) => {
    if (serverStatus !== 'offline') return res.status(400).json({success:false, msg:'Stop server first'});
    if (!req.file) return res.status(400).json({success:false, msg:'No file'});
    
    io.emit('log', '[System] World Zip received. Extracting...');
    setTimeout(() => {
        try {
            if (fs.existsSync('world')) fs.rmSync('world', {recursive:true, force:true});
            const zip = new AdmZip(req.file.path);
            zip.extractAllTo('.', true);
            fs.unlinkSync(req.file.path);
            io.emit('log', '[System] World restored successfully.');
        } catch(e) { io.emit('log', '[Error] Extraction failed: ' + e.message); }
    }, 100);
    res.json({success:true});
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

# --- 5. CREATE FRONTEND FILES ---
RUN mkdir -p public views

# LOGIN PAGE (With Forgot Password)
RUN cat << 'EOF' > public/login.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Admin Login</title>
<style>
    body { background: #000; color: #fff; font-family: 'Segoe UI', sans-serif; height: 100vh; display: flex; align-items: center; justify-content: center; overflow: hidden; margin: 0; }
    .bg-animation { position: fixed; top: 0; left: 0; width: 100%; height: 100%; z-index: -1; background: radial-gradient(circle at 50% 50%, #1a1a2e 0%, #000 100%); }
    .orb { position: absolute; border-radius: 50%; filter: blur(80px); opacity: 0.5; animation: float 10s infinite alternate; }
    .orb-1 { width: 300px; height: 300px; background: #6366f1; top: 10%; left: 20%; }
    .orb-2 { width: 400px; height: 400px; background: #ec4899; bottom: 10%; right: 20%; animation-delay: -5s; }
    @keyframes float { 0% { transform: translate(0,0); } 100% { transform: translate(30px, -30px); } }
    
    .login-card { background: rgba(255, 255, 255, 0.03); backdrop-filter: blur(20px); border: 1px solid rgba(255,255,255,0.1); padding: 50px; border-radius: 24px; width: 340px; text-align: center; box-shadow: 0 25px 50px -12px rgba(0,0,0,0.5); }
    h2 { font-weight: 200; letter-spacing: 4px; margin-bottom: 30px; font-size: 24px; text-transform: uppercase; }
    input { width: 100%; padding: 16px; margin-bottom: 16px; background: rgba(0,0,0,0.3); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; color: white; font-size: 14px; box-sizing: border-box; outline: none; transition: 0.3s; }
    input:focus { border-color: #6366f1; background: rgba(0,0,0,0.5); }
    button { width: 100%; padding: 16px; background: linear-gradient(135deg, #6366f1, #8b5cf6); color: white; border: none; border-radius: 12px; font-weight: bold; cursor: pointer; transition: 0.3s; font-size: 14px; letter-spacing: 1px; }
    button:hover { transform: translateY(-2px); box-shadow: 0 10px 20px rgba(99, 102, 241, 0.3); }
    .link { margin-top: 15px; font-size: 12px; color: #aaa; cursor: pointer; text-decoration: underline; }
    .hidden { display: none; }
</style>
</head>
<body>
<div class="bg-animation"><div class="orb orb-1"></div><div class="orb orb-2"></div></div>

<div class="login-card" id="loginMode">
    <h2 id="title">SYSTEM LOGIN</h2>
    <form id="authForm">
        <input id="user" placeholder="USERNAME" required>
        <input type="password" id="pass" placeholder="PASSWORD" required>
        <button type="submit">AUTHENTICATE</button>
    </form>
    <div class="link" onclick="toggleMode()">Forgot Password?</div>
</div>

<div class="login-card hidden" id="resetMode">
    <h2 style="color:#ec4899">ADMIN RESET</h2>
    <form id="resetForm">
        <input id="code" placeholder="BACKUP CODE" required>
        <input type="password" id="newPass" placeholder="NEW PASSWORD" required>
        <button type="submit" style="background:linear-gradient(135deg, #ec4899, #be185d)">RESET ACCESS</button>
    </form>
    <div class="link" onclick="toggleMode()">Back to Login</div>
</div>

<script>
    fetch('/api/check-setup').then(r=>r.json()).then(d=>{if(d.setupNeeded){document.getElementById('title').innerText='INITIAL SETUP';document.getElementById('authForm').dataset.action='signup'}});
    
    function toggleMode() {
        document.getElementById('loginMode').classList.toggle('hidden');
        document.getElementById('resetMode').classList.toggle('hidden');
    }

    document.getElementById('authForm').onsubmit=async(e)=>{
        e.preventDefault(); const user=document.getElementById('user').value; const pass=document.getElementById('pass').value; const action=e.target.dataset.action||'login';
        try { const res=await fetch('/api/auth',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:user,password:pass,action})});
        const data=await res.json(); if(data.success) window.location.href='/'; else alert(data.msg); } catch(err){ alert('Network Error'); }
    }

    document.getElementById('resetForm').onsubmit=async(e)=>{
        e.preventDefault(); const code=document.getElementById('code').value; const newPass=document.getElementById('newPass').value;
        try { const res=await fetch('/api/auth/reset',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code, newPassword: newPass})});
        const data=await res.json(); alert(data.msg); if(data.success) toggleMode(); } catch(err){ alert('Network Error'); }
    }
</script>
</body>
</html>
EOF

# --- DASHBOARD.HTML (With Folder Upload) ---
RUN cat << 'EOF' > views/dashboard.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>MC Panel Pro</title>
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
<style>
    :root { --glass: rgba(15, 15, 20, 0.85); --border: rgba(255, 255, 255, 0.08); --accent: #6366f1; --text: #e2e8f0; }
    body { margin: 0; font-family: 'Segoe UI', sans-serif; background: #050505; color: var(--text); height: 100vh; display: flex; overflow: hidden; }
    
    /* PARTICLES & BG */
    #particle-canvas { position: absolute; top:0; left:0; width:100%; height:100%; z-index:-1; }
    .bg-gradient { position: absolute; width:100%; height:100%; background: radial-gradient(circle at top right, #1e1b4b 0%, #000 70%); z-index:-2; }
    
    /* INTRO ANIMATION */
    .intro-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: #000; z-index: 9999; display: flex; justify-content: center; align-items: center; animation: fadeOut 1s ease-in-out 1.2s forwards; }
    .intro-text { font-size: 60px; font-weight: 800; letter-spacing: -2px; background: linear-gradient(to right, #fff, #6366f1); -webkit-background-clip: text; color: transparent; animation: splitIn 1s cubic-bezier(0.2, 0, 0.2, 1); opacity: 0; animation-fill-mode: forwards; }
    @keyframes splitIn { 0% { letter-spacing: 20px; opacity: 0; filter: blur(10px); } 100% { letter-spacing: -2px; opacity: 1; filter: blur(0); } }
    @keyframes fadeOut { to { opacity: 0; visibility: hidden; } }

    /* LAYOUT */
    .sidebar { width: 260px; background: var(--glass); backdrop-filter: blur(30px); border-right: 1px solid var(--border); display: flex; flex-direction: column; padding: 25px; z-index: 10; }
    .brand { font-size: 24px; font-weight: 800; color: #fff; margin-bottom: 40px; display: flex; align-items: center; gap: 12px; letter-spacing: -1px; }
    .nav-item { padding: 14px 16px; margin: 6px 0; border-radius: 12px; cursor: pointer; color: #94a3b8; transition: 0.3s; display: flex; align-items: center; gap: 14px; font-weight: 600; font-size: 14px; }
    .nav-item:hover, .nav-item.active { background: rgba(99, 102, 241, 0.1); color: #fff; border: 1px solid rgba(99, 102, 241, 0.15); box-shadow: 0 4px 12px rgba(99, 102, 241, 0.1); }
    .status-panel { margin-top: auto; padding: 20px; background: rgba(0,0,0,0.4); border-radius: 16px; border: 1px solid var(--border); }

    .main { flex: 1; padding: 40px; overflow-y: auto; position: relative; scroll-behavior: smooth; }
    .glass-card { background: var(--glass); backdrop-filter: blur(20px); border: 1px solid var(--border); border-radius: 20px; padding: 30px; margin-bottom: 25px; box-shadow: 0 20px 40px rgba(0,0,0,0.3); transition: 0.3s; }
    .glass-card:hover { border-color: rgba(255,255,255,0.15); }
    
    .page { display: none; opacity: 0; transform: translateY(20px); transition: 0.4s cubic-bezier(0.2, 0, 0.2, 1); }
    .page.active { display: block; opacity: 1; transform: translateY(0); }

    h2 { margin: 0 0 25px 0; font-size: 20px; font-weight: 600; color: #fff; display: flex; align-items: center; gap: 12px; padding-bottom: 15px; border-bottom: 1px solid var(--border); }
    
    .btn { padding: 12px 20px; border-radius: 10px; border: none; font-weight: 600; cursor: pointer; transition: 0.2s; color: white; display: inline-flex; align-items: center; gap: 8px; font-size: 13px; }
    .btn:hover { transform: translateY(-2px); filter: brightness(1.2); }
    .btn-primary { background: var(--accent); }
    .btn-danger { background: #ef4444; }
    .btn-success { background: #22c55e; }
    .btn-amber { background: #f59e0b; color: #000; }
    .btn-dark { background: #1e293b; border: 1px solid #334155; }

    input, select { width: 100%; padding: 14px; background: rgba(0,0,0,0.3); border: 1px solid var(--border); border-radius: 10px; color: white; margin-bottom: 15px; box-sizing: border-box; font-family: inherit; transition: 0.2s; }
    input:focus, select:focus { border-color: var(--accent); background: rgba(0,0,0,0.5); outline: none; }

    /* TERMINAL */
    .terminal-container { display: grid; grid-template-columns: 1fr 280px; gap: 25px; height: 65vh; }
    .term-box { display: flex; flex-direction: column; background: #09090b; border-radius: 16px; border: 1px solid var(--border); overflow: hidden; box-shadow: inset 0 0 20px rgba(0,0,0,0.5); }
    .terminal { flex: 1; overflow-y: auto; padding: 20px; font-family: 'Consolas', monospace; font-size: 13px; color: #cbd5e1; line-height: 1.5; }
    .cmd-input { background: #18181b; border: none; border-top: 1px solid var(--border); padding: 18px; color: white; outline: none; font-family: monospace; font-size: 14px; }

    /* FILE TABLE */
    .file-table { width: 100%; border-collapse: collapse; }
    .file-table th { text-align: left; padding: 10px; color: #64748b; font-size: 12px; text-transform: uppercase; font-weight: 600; border-bottom: 1px solid var(--border); }
    .file-table td { padding: 12px 10px; border-bottom: 1px solid rgba(255,255,255,0.03); font-size: 14px; }
    .file-row:hover { background: rgba(255,255,255,0.03); }
    .file-icon { width: 24px; text-align: center; margin-right: 10px; color: var(--accent); }
    .folder-icon { color: #facc15; }
    .file-link { cursor: pointer; display: flex; align-items: center; color: #e2e8f0; text-decoration: none; }
    .file-link:hover { color: #fff; }

    /* OVERLAY */
    #uploadOverlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.8); backdrop-filter: blur(10px); z-index: 99999; display: none; align-items: center; justify-content: center; }
    .upload-modal { background: #18181b; border: 1px solid #333; padding: 40px; border-radius: 24px; width: 400px; text-align: center; box-shadow: 0 25px 50px rgba(0,0,0,0.5); }
    .progress-track { width: 100%; height: 10px; background: #333; border-radius: 5px; overflow: hidden; margin-top: 20px; }
    .progress-fill { height: 100%; background: var(--accent); width: 0%; transition: width 0.1s; }
</style>
</head>
<body>

<div class="intro-overlay"><div class="intro-text">MC PANEL PRO</div></div>
<div class="bg-gradient"></div>
<canvas id="particle-canvas"></canvas>

<!-- UPLOAD OVERLAY -->
<div id="uploadOverlay">
    <div class="upload-modal">
        <i class="fas fa-cloud-upload-alt" style="font-size:40px; color:#6366f1; margin-bottom:20px"></i>
        <h3 style="margin:0; font-size:20px">Uploading...</h3>
        <p id="uploadText" style="color:#aaa; margin-top:10px">Please wait, do not close this window.</p>
        <div class="progress-track"><div id="uploadBar" class="progress-fill"></div></div>
        <div id="uploadPercent" style="margin-top:10px; font-weight:bold; color:var(--accent)">0%</div>
    </div>
</div>

<div class="sidebar">
    <div class="brand"><i class="fas fa-cube"></i> PANEL PRO</div>
    <div class="nav-item active" onclick="nav('console')"><i class="fas fa-terminal"></i> Console</div>
    <div class="nav-item" onclick="nav('players')"><i class="fas fa-users"></i> Players</div>
    <div class="nav-item" onclick="nav('files')"><i class="fas fa-folder-open"></i> File Manager</div>
    <div class="nav-item" onclick="nav('world')"><i class="fas fa-globe"></i> World</div>
    <div class="nav-item" onclick="nav('settings')"><i class="fas fa-sliders"></i> Settings</div>
    <div class="nav-item admin-only" onclick="nav('users')"><i class="fas fa-user-shield"></i> Users</div>
    <div class="nav-item" onclick="location.href='/api/logout'"><i class="fas fa-sign-out-alt"></i> Logout</div>
    
    <div class="status-panel">
        <div style="font-size:12px; color:#94a3b8; margin-bottom:12px; display:flex; align-items:center; justify-content:space-between">
            <span>STATUS</span>
            <span id="statusText" style="color:#f87171; font-weight:bold">OFFLINE</span>
        </div>
        <div style="display:flex; gap:8px; margin-bottom:8px">
            <button class="btn btn-success" style="flex:1; justify-content:center" onclick="cmd('__start__')">Start</button>
            <button class="btn btn-danger" style="flex:1; justify-content:center" onclick="cmd('__stop__')">Stop</button>
        </div>
        <button class="btn btn-amber" style="width:100%; justify-content:center" onclick="cmd('__restart__')"><i class="fas fa-redo"></i> Restart</button>
    </div>
</div>

<div class="main">
    
    <!-- CONSOLE -->
    <div id="console" class="page active">
        <div class="glass-card" style="padding:15px; border-left: 4px solid var(--accent);">
            <div style="display:flex; align-items:center; gap:15px">
                <i class="fas fa-info-circle" style="font-size:24px; color:var(--accent)"></i>
                <div>
                    <h4 style="margin:0; font-size:16px; color:#fff">Server Information</h4>
                    <span style="font-size:13px; color:#aaa">Running PaperMC. Use "Stop" before changing versions or uploading worlds.</span>
                </div>
            </div>
        </div>

        <div class="terminal-container">
            <div class="term-box">
                <div id="term" class="terminal"></div>
                <input class="cmd-input" id="cmdInput" placeholder="> Type a command..." autocomplete="off">
            </div>
            <div style="display:flex; flex-direction:column; gap:20px">
                <div class="glass-card" style="margin:0; height:100%; padding:20px">
                    <h3 style="margin-top:0; font-size:14px; color:#64748b; letter-spacing:1px">QUICK ACTIONS</h3>
                    <div style="display:flex; flex-direction:column; gap:10px">
                        <button class="btn btn-dark" onclick="cmd('time set day')"><i class="fas fa-sun"></i> Set Day</button>
                        <button class="btn btn-dark" onclick="cmd('time set night')"><i class="fas fa-moon"></i> Set Night</button>
                        <button class="btn btn-dark" onclick="cmd('weather clear')"><i class="fas fa-cloud-sun"></i> Clear Rain</button>
                        <hr style="width:100%; border:0; border-top:1px solid rgba(255,255,255,0.1); margin:10px 0">
                        <button class="btn btn-dark" onclick="cmd('gamemode survival @a')"><i class="fas fa-heart"></i> Survival</button>
                        <button class="btn btn-dark" onclick="cmd('gamemode creative @a')"><i class="fas fa-cube"></i> Creative</button>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- PLAYERS -->
    <div id="players" class="page">
        <div class="glass-card">
            <h2><i class="fas fa-users"></i> Player Manager</h2>
            <div style="display:flex; gap:12px; flex-wrap:wrap">
                <input id="targetPlayer" placeholder="Player Name" style="width:250px; margin:0">
                <button class="btn btn-primary" onclick="pAct('op')">OP</button>
                <button class="btn btn-dark" onclick="pAct('deop')">DeOP</button>
                <button class="btn btn-danger" onclick="pAct('kick')">Kick</button>
                <button class="btn btn-danger" onclick="pAct('ban')">Ban</button>
                <button class="btn btn-success" onclick="pAct('pardon')">Unban</button>
            </div>
        </div>
    </div>

    <!-- FILE MANAGER (LIST VIEW WITH FOLDER UPLOAD) -->
    <div id="files" class="page">
        <div class="glass-card">
            <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:20px">
                <h2 style="border:none; margin:0; padding:0">File Manager</h2>
                <div style="display:flex; gap:10px">
                    <button class="btn btn-dark" onclick="loadFile('.')"><i class="fas fa-home"></i></button>
                    <button class="btn btn-dark" onclick="goUp()"><i class="fas fa-arrow-up"></i></button>
                    <!-- File Upload -->
                    <button class="btn btn-primary" onclick="document.getElementById('fUpload').click()">Upload File</button>
                    <input type="file" id="fUpload" hidden onchange="uploadFiles(this)">
                    <!-- Folder Upload (New) -->
                    <button class="btn btn-primary" onclick="document.getElementById('folderUpload').click()">Upload Folder</button>
                    <input type="file" id="folderUpload" hidden webkitdirectory directory multiple onchange="uploadFiles(this)">
                </div>
            </div>
            <div style="background:rgba(0,0,0,0.3); padding:10px; border-radius:8px; margin-bottom:15px; font-family:monospace; color:#aaa" id="currentPath">/app</div>
            <table class="file-table">
                <thead><tr><th>Name</th><th>Size</th><th>Date</th><th style="text-align:right">Actions</th></tr></thead>
                <tbody id="fileList"></tbody>
            </table>
        </div>
    </div>

    <!-- WORLD -->
    <div id="world" class="page">
        <div class="glass-card">
            <h2><i class="fas fa-globe"></i> World Manager</h2>
            <div style="display:grid; grid-template-columns: 1fr 1fr; gap:30px">
                <div style="background:rgba(255,255,255,0.02); padding:25px; border-radius:16px; border:1px solid var(--border)">
                    <h3 style="margin-top:0">Download World</h3>
                    <p style="color:#aaa; font-size:14px">Backup the current world as a ZIP.</p>
                    <button class="btn btn-primary" onclick="location.href='/api/world/download'">Download ZIP</button>
                </div>
                <div style="background:rgba(255,255,255,0.02); padding:25px; border-radius:16px; border:1px solid var(--border)">
                    <h3 style="margin-top:0">Restore World</h3>
                    <p style="color:#f87171; font-size:14px">Warning: Overwrites existing world data.</p>
                    <input type="file" id="worldZip" accept=".zip">
                    <button class="btn btn-danger" onclick="uploadWorldZip()">Upload & Restore</button>
                </div>
            </div>
        </div>
    </div>

    <!-- SETTINGS -->
    <div id="settings" class="page">
        <div class="glass-card">
            <h2><i class="fas fa-sliders"></i> Settings</h2>
            <div style="max-width:600px">
                <label>RAM Allocation (GB) <span class="badge admin-only" style="background:#facc15; color:#000; padding:2px 6px; border-radius:4px; font-size:10px; font-weight:bold">ADMIN</span></label>
                <input type="number" id="ram" class="admin-input">
                
                <label>PaperMC Version</label>
                <input type="text" id="ver">
                
                <label>Render Distance</label>
                <input type="number" id="dist">
                
                <label>Online Mode</label>
                <select id="online">
                    <option value="true">True (Premium)</option>
                    <option value="false">False (Cracked)</option>
                </select>
                
                <div style="text-align:right; margin-top:20px">
                    <button class="btn btn-primary" onclick="saveSettings()">Save Changes</button>
                </div>
            </div>
        </div>
    </div>

    <!-- USERS -->
    <div id="users" class="page">
        <div class="glass-card">
            <h2><i class="fas fa-user-shield"></i> User Management</h2>
            <div style="display:grid; grid-template-columns: 1fr 1fr 1fr auto; gap:15px; margin-bottom:25px">
                <input id="newUser" placeholder="Username" style="margin:0">
                <input id="newPass" placeholder="Password" style="margin:0">
                <select id="newRole" style="margin:0"><option value="user">User</option><option value="admin">Admin</option></select>
                <button class="btn btn-success" onclick="createUser()">Add</button>
            </div>
            <div id="userList"></div>
        </div>
    </div>

</div>

<script src="/socket.io/socket.io.js"></script>
<script>
    const sock = io();
    let currPath = '';
    let isAdmin = false;

    // --- PARTICLES ---
    const canvas = document.getElementById("particle-canvas");
    const ctx = canvas.getContext("2d");
    let particles = [];
    function resize(){ canvas.width=window.innerWidth; canvas.height=window.innerHeight; }
    window.addEventListener('resize', resize); resize();
    for(let i=0;i<50;i++) particles.push({x:Math.random()*canvas.width,y:Math.random()*canvas.height,vx:(Math.random()-0.5)*0.5,vy:(Math.random()-0.5)*0.5,size:Math.random()*2});
    function animate(){
        ctx.clearRect(0,0,canvas.width,canvas.height);
        ctx.fillStyle = "rgba(255,255,255,0.3)";
        particles.forEach(p=>{
            p.x+=p.vx; p.y+=p.vy;
            if(p.x<0)p.x=canvas.width; if(p.x>canvas.width)p.x=0; if(p.y<0)p.y=canvas.height; if(p.y>canvas.height)p.y=0;
            ctx.beginPath(); ctx.arc(p.x,p.y,p.size,0,Math.PI*2); ctx.fill();
        });
        requestAnimationFrame(animate);
    }
    animate();

    // --- LOGIC ---
    fetch('/api/user-info').then(r=>r.json()).then(u => {
        isAdmin = (u.role === 'admin');
        if(!isAdmin) {
            document.querySelectorAll('.admin-only').forEach(e=>e.style.display='inline-block');
            document.querySelectorAll('.admin-input').forEach(e=>{e.disabled=true;e.style.opacity="0.5";});
            document.querySelector('.nav-item.admin-only').style.display='none';
        }
        if(isAdmin) loadUsers();
    });

    function nav(id) {
        document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
        document.querySelectorAll('.nav-item').forEach(i => i.classList.remove('active'));
        document.getElementById(id).classList.add('active');
        event.currentTarget.classList.add('active');
        if(id==='files') loadFile('');
        if(id==='settings') loadSettings();
    }

    sock.on('log', d => { const t = document.getElementById('term'); const l = document.createElement('div'); l.textContent = d; t.appendChild(l); t.scrollTop = t.scrollHeight; });
    sock.on('status', s => { 
        document.getElementById('statusText').innerText = s.toUpperCase();
        document.getElementById('statusText').style.color = (s==='online'?'#4ade80':s==='starting'?'#facc15':'#f87171');
    });

    function cmd(c) { sock.emit('command', c); }
    document.getElementById('cmdInput').addEventListener('keydown', e => { if(e.key==='Enter'&&e.target.value) { cmd(e.target.value); e.target.value=''; } });
    function pAct(a) { const p=document.getElementById('targetPlayer').value; if(p)cmd(a+' '+p); else alert('Enter name'); }

    // FILE MANAGER
    function loadFile(path) {
        currPath = path;
        document.getElementById('currentPath').innerText = '/app/' + path;
        fetch('/api/files?path='+path).then(r=>r.json()).then(files => {
            const tbody = document.getElementById('fileList'); tbody.innerHTML = '';
            files.forEach(f => {
                const tr = document.createElement('tr'); tr.className='file-row';
                const icon = f.isDir ? 'fa-folder folder-icon' : 'fa-file-alt';
                tr.innerHTML = `
                    <td><a class="file-link" onclick="${f.isDir ? `loadFile(currPath ? currPath+'/'+'${f.name}' : '${f.name}')` : ''}"><i class="fas ${icon} file-icon"></i> ${f.name}</a></td>
                    <td style="color:#aaa">${f.size}</td>
                    <td style="color:#aaa">${f.date}</td>
                    <td style="text-align:right">
                        ${!f.isDir ? `<button class="btn btn-dark btn-sm" onclick="window.open('/api/files/download?path=${path?path+'/'+f.name:f.name}')"><i class="fas fa-download"></i></button>` : ''}
                        <button class="btn btn-danger btn-sm" onclick="delFile('${f.name}')"><i class="fas fa-trash"></i></button>
                    </td>
                `;
                tbody.appendChild(tr);
            });
        });
    }
    function delFile(n) { if(confirm('Delete '+n+'?')) fetch('/api/files/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:currPath?currPath+'/'+n:n})}).then(()=>loadFile(currPath)); }
    function goUp() { const p = currPath.split('/'); p.pop(); loadFile(p.join('/')); }

    // UNIVERSAL UPLOAD OVERLAY
    function performUpload(url, fd) {
        const overlay = document.getElementById('uploadOverlay');
        const bar = document.getElementById('uploadBar');
        const txt = document.getElementById('uploadPercent');
        const status = document.getElementById('uploadText');
        
        overlay.style.display = 'flex';
        status.innerText = 'Uploading data...';
        bar.style.width = '0%'; txt.innerText = '0%';

        const xhr = new XMLHttpRequest();
        xhr.upload.onprogress = e => {
            if(e.lengthComputable) {
                const p = Math.round((e.loaded/e.total)*100);
                bar.style.width = p + '%'; txt.innerText = p + '%';
            }
        };
        xhr.onload = () => {
            status.innerText = 'Processing/Extracting...';
            setTimeout(() => {
                overlay.style.display = 'none';
                if(xhr.status === 200) { 
                    // Use a JSON response check if possible, or just assume 200 is success
                    try {
                        const res = JSON.parse(xhr.responseText);
                        if(res.success) { alert('Success!'); if(url.includes('files')) loadFile(currPath); }
                        else alert('Failed: ' + res.msg);
                    } catch(e) { alert('Success!'); if(url.includes('files')) loadFile(currPath); }
                }
                else alert('Failed: ' + xhr.responseText);
            }, 500);
        };
        xhr.open('POST', url); xhr.send(fd);
    }

    function uploadFiles(i) { 
        if(i.files.length > 0) { 
            const fd=new FormData(); 
            for(let j=0; j<i.files.length; j++) {
                fd.append('files', i.files[j]);
            }
            fd.append('path', currPath); 
            performUpload('/api/files/upload', fd); 
        } 
    }
    
    function uploadWorldZip() { const f=document.getElementById('worldZip').files[0]; if(f) { const fd=new FormData(); fd.append('file',f); performUpload('/api/world/upload', fd); } else alert('Select Zip'); }

    // SETTINGS & USERS
    function loadSettings() { fetch('/api/settings').then(r=>r.json()).then(d => { document.getElementById('ram').value=d.ram; document.getElementById('ver').value=d.version; document.getElementById('dist').value=d.viewDistance; document.getElementById('online').value=d.onlineMode; }); }
    function saveSettings() { const d={ram:document.getElementById('ram').value,version:document.getElementById('ver').value,viewDistance:document.getElementById('dist').value,onlineMode:document.getElementById('online').value}; fetch('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)}).then(r=>r.json()).then(d=>{if(d.success)alert('Saved!');else alert(d.msg);}); }
    
    function loadUsers() { fetch('/api/users/list').then(r=>r.json()).then(l => { const div=document.getElementById('userList'); div.innerHTML=''; l.forEach(u => { div.innerHTML+=`<div style="background:rgba(255,255,255,0.05); padding:10px; border-radius:8px; margin-bottom:5px; display:flex; justify-content:space-between; align-items:center"><div><span style="font-weight:bold">${u.username}</span> <span style="font-size:11px; background:${u.role==='admin'?'#6366f1':'#333'}; padding:2px 6px; border-radius:4px">${u.role}</span></div><button class="btn btn-danger btn-sm" onclick="delUser('${u.username}')"><i class="fas fa-trash"></i></button></div>`; }); }); }
    function createUser() { const u=document.getElementById('newUser').value; const p=document.getElementById('newPass').value; const r=document.getElementById('newRole').value; fetch('/api/users/create',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p,role:r})}).then(r=>r.json()).then(d=>{if(d.success)loadUsers();else alert(d.msg);}); }
    function delUser(u) { if(confirm('Delete '+u+'?')) fetch('/api/users/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u})}).then(r=>r.json()).then(d=>{if(d.success)loadUsers();else alert(d.msg);}); }
</script>
</body>
</html>
EOF

# --- 6. EXPOSE PORTS ---
EXPOSE 20000 25565

# --- 7. START ---
CMD ["node", "server.js"]
