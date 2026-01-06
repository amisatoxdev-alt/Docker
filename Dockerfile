FROM ubuntu:22.04

# --- 1. SETUP ENVIRONMENT ---
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080

# --- 2. INSTALL DEPENDENCIES ---
# Java 21 (for Minecraft 1.20+), Node.js, and Zip tools for map uploads
RUN apt-get update && apt-get install -y \
    curl wget git tar sudo unzip zip \
    openjdk-21-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# --- 3. SETUP APP DIRECTORY ---
WORKDIR /app

# Initialize Node Project & Install Libraries
# We use 'express' for the web server, 'socket.io' for the terminal, 'multer' for uploads
RUN npm init -y && \
    npm install express socket.io multer fs-extra body-parser express-session adm-zip

# Download Minecraft Server (Paper 1.20.4) - You can change this version link if you want
RUN wget -O server.jar https://api.papermc.io/v2/projects/paper/versions/1.20.4/builds/496/downloads/paper-1.20.4-496.jar
RUN echo "eula=true" > eula.txt

# --- 4. CREATE THE BACKEND (server.js) ---
# This is the "Brain" of your panel. It handles Login, Terminal, and Files.
RUN echo "const express = require('express'); \n\
const http = require('http'); \n\
const { Server } = require('socket.io'); \n\
const { spawn } = require('child_process'); \n\
const fs = require('fs-extra'); \n\
const path = require('path'); \n\
const session = require('express-session'); \n\
const bodyParser = require('body-parser'); \n\
const multer = require('multer'); \n\
const AdmZip = require('adm-zip'); \n\
\n\
const app = express(); \n\
const server = http.createServer(app); \n\
const io = new Server(server); \n\
const upload = multer({ dest: 'uploads/' }); \n\
\n\
// --- CONFIGURATION --- \n\
const USER_FILE = 'users.json'; \n\
let mcProcess = null; \n\
let logs = []; \n\
\n\
app.use(express.static('public')); \n\
app.use(bodyParser.json()); \n\
app.use(bodyParser.urlencoded({ extended: true })); \n\
app.use(session({ secret: 'railway-secret', resave: false, saveUninitialized: true })); \n\
\n\
// --- AUTH MIDDLEWARE --- \n\
function checkAuth(req, res, next) { \n\
    if (req.session.loggedin) next(); \n\
    else res.redirect('/login.html'); \n\
} \n\
\n\
// --- ROUTES --- \n\
\n\
// 1. LOGIN / SIGNUP API \n\
app.post('/api/auth', (req, res) => { \n\
    const { username, password, action } = req.body; \n\
    let users = {}; \n\
    if (fs.existsSync(USER_FILE)) users = fs.readJsonSync(USER_FILE); \n\
    \n\
    if (action === 'signup') { \n\
        if (Object.keys(users).length > 0) return res.json({ success: false, msg: 'Admin account already exists.' }); \n\
        users[username] = password; \n\
        fs.writeJsonSync(USER_FILE, users); \n\
        req.session.loggedin = true; \n\
        return res.json({ success: true }); \n\
    } else { \n\
        if (users[username] && users[username] === password) { \n\
            req.session.loggedin = true; \n\
            return res.json({ success: true }); \n\
        } \n\
        return res.json({ success: false, msg: 'Invalid credentials' }); \n\
    } \n\
}); \n\
\n\
app.get('/api/check-setup', (req, res) => { \n\
    const exists = fs.existsSync(USER_FILE); \n\
    res.json({ setupNeeded: !exists }); \n\
}); \n\
\n\
// 2. DASHBOARD (Protected) \n\
app.get('/', checkAuth, (req, res) => { \n\
    res.sendFile(path.join(__dirname, 'public/index.html')); \n\
}); \n\
\n\
// 3. FILE MANAGER API \n\
app.get('/api/files', checkAuth, (req, res) => { \n\
    const dir = req.query.path || '.'; \n\
    const safePath = path.resolve(__dirname, dir); \n\
    if (!safePath.startsWith(__dirname)) return res.status(403).send('Access denied'); \n\
    \n\
    fs.readdir(safePath, { withFileTypes: true }, (err, files) => { \n\
        if (err) return res.json([]); \n\
        const result = files.map(f => ({ name: f.name, isDir: f.isDirectory() })); \n\
        res.json(result); \n\
    }); \n\
}); \n\
\n\
// Upload Map (Zip) \n\
app.post('/api/upload', checkAuth, upload.single('file'), (req, res) => { \n\
    const targetPath = req.body.path || '.'; \n\
    if (req.file.originalname.endsWith('.zip')) { \n\
        const zip = new AdmZip(req.file.path); \n\
        zip.extractAllTo(path.join(__dirname, targetPath), true); \n\
        fs.unlinkSync(req.file.path); \n\
    } else { \n\
        fs.moveSync(req.file.path, path.join(__dirname, targetPath, req.file.originalname)); \n\
    } \n\
    res.redirect('/'); \n\
}); \n\
\n\
// --- MINECRAFT PROCESS --- \n\
function startServer() { \n\
    if (mcProcess) return; \n\
    // Memory Settings: 1GB RAM (Change -Xmx if you have more) \n\
    mcProcess = spawn('java', ['-Xmx1G', '-Xms1G', '-jar', 'server.jar', 'nogui']); \n\
    \n\
    mcProcess.stdout.on('data', (data) => { \n\
        const line = data.toString(); \n\
        logs.push(line); \n\
        if (logs.length > 500) logs.shift(); \n\
        io.emit('log', line); \n\
    }); \n\
    \n\
    mcProcess.on('close', () => { \n\
        mcProcess = null; \n\
        io.emit('log', '--- SERVER STOPPED ---'); \n\
    }); \n\
} \n\
\n\
// --- SOCKET.IO --- \n\
io.on('connection', (socket) => { \n\
    socket.emit('history', logs.join('')); \n\
    \n\
    socket.on('command', (cmd) => { \n\
        if (mcProcess && mcProcess.stdin) { \n\
            mcProcess.stdin.write(cmd + '\\n'); \n\
        } else if (cmd === 'start') { \n\
            startServer(); \n\
        } \n\
    }); \n\
}); \n\
\n\
// Start automatically on boot \n\
startServer(); \n\
\n\
const port = process.env.PORT || 8080; \n\
server.listen(port, () => console.log('Panel running on port ' + port)); \n\
" > server.js

# --- 5. CREATE FRONTEND FILES ---
RUN mkdir public

# LOGIN PAGE
RUN echo "<!DOCTYPE html> \n\
<html><head><title>Panel Login</title><style>body{background:#222;color:white;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh} form{background:#333;padding:20px;border-radius:8px} input{display:block;margin:10px 0;padding:8px;width:100%} button{width:100%;padding:10px;background:#007bff;color:white;border:none;cursor:pointer}</style></head> \n\
<body> \n\
<form id='authForm'> \n\
    <h2 id='title'>Login</h2> \n\
    <input type='text' id='user' placeholder='Username' required> \n\
    <input type='password' id='pass' placeholder='Password' required> \n\
    <button type='submit'>Submit</button> \n\
</form> \n\
<script> \n\
    fetch('/api/check-setup').then(r=>r.json()).then(d => { \n\
        if(d.setupNeeded) { \n\
            document.getElementById('title').innerText = 'Setup Admin Account'; \n\
            document.getElementById('authForm').dataset.action = 'signup'; \n\
        } \n\
    }); \n\
    document.getElementById('authForm').onsubmit = async (e) => { \n\
        e.preventDefault(); \n\
        const user = document.getElementById('user').value; \n\
        const pass = document.getElementById('pass').value; \n\
        const action = e.target.dataset.action || 'login'; \n\
        const res = await fetch('/api/auth', { \n\
            method: 'POST', headers:{'Content-Type':'application/json'}, \n\
            body: JSON.stringify({username:user, password:pass, action}) \n\
        }); \n\
        const data = await res.json(); \n\
        if(data.success) location.href = '/'; \n\
        else alert(data.msg); \n\
    }; \n\
</script> \n\
</body></html>" > public/login.html

# DASHBOARD PAGE
RUN echo "<!DOCTYPE html> \n\
<html><head><title>MC Control Panel</title> \n\
<style> \n\
    body { background: #1a1a1a; color: #eee; font-family: monospace; display: grid; grid-template-columns: 250px 1fr; gap: 10px; height: 98vh; margin: 0; padding: 10px; } \n\
    .sidebar { background: #252525; padding: 10px; border-radius: 5px; display: flex; flex-direction: column; gap: 10px; } \n\
    .main { display: flex; flex-direction: column; gap: 10px; } \n\
    .terminal { flex: 1; background: #000; padding: 10px; overflow-y: auto; white-space: pre-wrap; font-size: 14px; border-radius: 5px; } \n\
    .controls { display: grid; grid-template-columns: repeat(2, 1fr); gap: 5px; } \n\
    button, input[type=file]::file-selector-button { padding: 8px; background: #444; color: white; border: none; border-radius: 4px; cursor: pointer; } \n\
    button:hover { background: #666; } \n\
    .btn-green { background: #28a745; } .btn-red { background: #dc3545; } \n\
    input { padding: 8px; background: #333; color: white; border: 1px solid #555; border-radius: 4px; } \n\
    #file-list div { padding: 5px; cursor: pointer; border-bottom: 1px solid #333; } \n\
    #file-list div:hover { background: #333; } \n\
</style></head> \n\
<body> \n\
    <div class='sidebar'> \n\
        <h3>Controls</h3> \n\
        <button class='btn-green' onclick=\"cmd('start')\">Start Server</button> \n\
        <button class='btn-red' onclick=\"cmd('stop')\">Stop Server</button> \n\
        <hr> \n\
        <button onclick=\"cmd('gamemode creative @a')\">GM Creative</button> \n\
        <button onclick=\"cmd('gamemode survival @a')\">GM Survival</button> \n\
        <button onclick=\"cmd('time set day')\">Time Day</button> \n\
        <button onclick=\"cmd('time set night')\">Time Night</button> \n\
        <hr> \n\
        <input id='targetPlayer' placeholder='Player Name'> \n\
        <div class='controls'> \n\
            <button class='btn-red' onclick=\"action('ban')\">Ban</button> \n\
            <button class='btn-green' onclick=\"action('op')\">Op</button> \n\
        </div> \n\
        <hr> \n\
        <h3>File Manager</h3> \n\
        <form action='/api/upload' method='post' enctype='multipart/form-data'> \n\
            <small>Upload Map .zip or File</small> \n\
            <input type='file' name='file' required> \n\
            <button type='submit' style='width:100%; margin-top:5px'>Upload</button> \n\
        </form> \n\
        <div id='file-list' style='overflow-y:auto; height: 200px;'></div> \n\
    </div> \n\
    <div class='main'> \n\
        <div class='terminal' id='term'></div> \n\
        <div style='display:flex; gap:5px'> \n\
            <input id='cmdInput' style='flex:1' placeholder='Type command...' onkeypress='if(event.key===\"Enter\") send()'> \n\
            <button onclick='send()'>Send</button> \n\
        </div> \n\
    </div> \n\
<script src='/socket.io/socket.io.js'></script> \n\
<script> \n\
    const socket = io(); \n\
    const term = document.getElementById('term'); \n\
    \n\
    socket.on('log', msg => { \n\
        const l = document.createElement('div'); l.textContent = msg; term.appendChild(l); \n\
        term.scrollTop = term.scrollHeight; \n\
    }); \n\
    socket.on('history', msg => { term.textContent = msg; term.scrollTop = term.scrollHeight; }); \n\
    \n\
    function cmd(c) { socket.emit('command', c); } \n\
    function send() { \n\
        const i = document.getElementById('cmdInput'); \n\
        if(i.value) { cmd(i.value); i.value=''; } \n\
    } \n\
    function action(act) { \n\
        const p = document.getElementById('targetPlayer').value; \n\
        if(p) cmd(act + ' ' + p); else alert('Enter player name'); \n\
    } \n\
    \n\
    // Simple File Lister \n\
    fetch('/api/files').then(r=>r.json()).then(files => { \n\
        const fl = document.getElementById('file-list'); \n\
        files.forEach(f => { \n\
            const d = document.createElement('div'); \n\
            d.textContent = (f.isDir ? '📁 ' : '📄 ') + f.name; \n\
            fl.appendChild(d); \n\
        }); \n\
    }); \n\
</script> \n\
</body></html>" > public/index.html

# --- 6. START SERVER ---
EXPOSE 8080 25565
CMD ["node", "server.js"]
