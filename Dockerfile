FROM ubuntu:22.04

# --- 1. SETUP ENVIRONMENT ---
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080

# --- 2. INSTALL DEPENDENCIES ---
# Install Java 21 (Required for MC 1.20+), Node.js, and Zip tools
RUN apt-get update && apt-get install -y \
    curl wget git tar sudo unzip zip \
    openjdk-21-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# --- 3. SETUP APP DIRECTORY ---
WORKDIR /app

# Install Node Libraries
RUN npm init -y && \
    npm install express socket.io multer fs-extra body-parser express-session adm-zip

# Download Minecraft Server (Paper 1.20.4)
RUN wget -O server.jar https://api.papermc.io/v2/projects/paper/versions/1.20.4/builds/496/downloads/paper-1.20.4-496.jar
RUN echo "eula=true" > eula.txt

# --- 4. CREATE BACKEND (server.js) ---
# We use 'cat' instead of 'echo' to prevent syntax errors
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

const app = express();
const server = http.createServer(app);
const io = new Server(server);
const upload = multer({ dest: 'uploads/' });

const USER_FILE = 'users.json';
let mcProcess = null;
let logs = [];

app.use(express.static('public'));
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(session({ secret: 'railway-secret', resave: false, saveUninitialized: true }));

// --- AUTH MIDDLEWARE ---
function checkAuth(req, res, next) {
    if (req.session.loggedin) next();
    else res.redirect('/login.html');
}

// --- API ROUTES ---

// Login / Signup Logic
app.post('/api/auth', (req, res) => {
    const { username, password, action } = req.body;
    let users = {};
    if (fs.existsSync(USER_FILE)) users = fs.readJsonSync(USER_FILE, { throws: false }) || {};
    
    if (action === 'signup') {
        if (Object.keys(users).length > 0) return res.json({ success: false, msg: 'Admin account already exists.' });
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

app.get('/api/check-setup', (req, res) => {
    let users = {};
    if (fs.existsSync(USER_FILE)) users = fs.readJsonSync(USER_FILE, { throws: false }) || {};
    res.json({ setupNeeded: Object.keys(users).length === 0 });
});

// Dashboard Route
app.get('/', checkAuth, (req, res) => {
    res.sendFile(path.join(__dirname, 'public/index.html'));
});

// File Manager: List Files
app.get('/api/files', checkAuth, (req, res) => {
    const dir = req.query.path || '.';
    const safePath = path.resolve(__dirname, dir);
    if (!safePath.startsWith(__dirname)) return res.status(403).send('Access denied');
    
    fs.readdir(safePath, { withFileTypes: true }, (err, files) => {
        if (err) return res.json([]);
        const result = files.map(f => ({ name: f.name, isDir: f.isDirectory() }));
        res.json(result);
    });
});

// File Manager: Upload Zip
app.post('/api/upload', checkAuth, upload.single('file'), (req, res) => {
    const targetPath = req.body.path || '.';
    if (req.file && req.file.originalname.endsWith('.zip')) {
        try {
            const zip = new AdmZip(req.file.path);
            zip.extractAllTo(path.join(__dirname, targetPath), true);
            fs.unlinkSync(req.file.path);
        } catch (e) { console.error(e); }
    } else if (req.file) {
        fs.moveSync(req.file.path, path.join(__dirname, targetPath, req.file.originalname), { overwrite: true });
    }
    res.redirect('/');
});

// --- MINECRAFT SERVER LOGIC ---
function startServer() {
    if (mcProcess) return;
    console.log('Starting Minecraft Server...');
    
    // Memory Limit: 1GB (Adjust based on your Railway plan)
    mcProcess = spawn('java', ['-Xmx1G', '-Xms1G', '-jar', 'server.jar', 'nogui']);
    
    mcProcess.stdout.on('data', (data) => {
        const line = data.toString();
        logs.push(line);
        if (logs.length > 500) logs.shift();
        io.emit('log', line);
        process.stdout.write(line);
    });
    
    mcProcess.stderr.on('data', (data) => {
        const line = data.toString();
        io.emit('log', line);
        process.stdout.write(line);
    });
    
    mcProcess.on('close', () => {
        mcProcess = null;
        const msg = '\n--- SERVER STOPPED ---\n';
        logs.push(msg);
        io.emit('log', msg);
    });
}

// --- WEBSOCKET FOR TERMINAL ---
io.on('connection', (socket) => {
    socket.emit('history', logs.join(''));
    
    socket.on('command', (cmd) => {
        console.log('Web Command:', cmd);
        if (cmd === 'start') {
            startServer();
        } else if (cmd === 'stop' && mcProcess) {
            mcProcess.stdin.write('stop\n');
        } else if (mcProcess && mcProcess.stdin) {
            mcProcess.stdin.write(cmd + '\n');
        }
    });
});

// Start Server on Boot
startServer();

const port = process.env.PORT || 8080;
server.listen(port, () => console.log('Panel running on port ' + port));
EOF

# --- 5. CREATE FRONTEND FILES ---
RUN mkdir public

# Create Login HTML
RUN cat << 'EOF' > public/login.html
<!DOCTYPE html>
<html>
<head>
    <title>Panel Login</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        body{background:#111;color:#eee;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0}
        form{background:#222;padding:30px;border-radius:10px;box-shadow:0 0 10px rgba(0,0,0,0.5);width:300px}
        input{display:block;margin:15px 0;padding:10px;width:100%;box-sizing:border-box;background:#333;border:1px solid #444;color:white;border-radius:5px}
        button{width:100%;padding:10px;background:#007bff;color:white;border:none;border-radius:5px;cursor:pointer;font-weight:bold}
        button:hover{background:#0056b3}
        h2{text-align:center;margin-top:0}
    </style>
</head>
<body>
<form id='authForm'>
    <h2 id='title'>Login</h2>
    <input type='text' id='user' placeholder='Username' required>
    <input type='password' id='pass' placeholder='Password' required>
    <button type='submit'>Submit</button>
</form>
<script>
    fetch('/api/check-setup').then(r=>r.json()).then(d => {
        if(d.setupNeeded) {
            document.getElementById('title').innerText = 'Setup Admin Account';
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

# Create Dashboard HTML
RUN cat << 'EOF' > public/index.html
<!DOCTYPE html>
<html>
<head>
    <title>MC Control Panel</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        body { background: #111; color: #eee; font-family: monospace; display: grid; grid-template-columns: 260px 1fr; gap: 10px; height: 98vh; margin: 0; padding: 10px; }
        .sidebar { background: #1e1e1e; padding: 15px; border-radius: 8px; display: flex; flex-direction: column; gap: 12px; border: 1px solid #333; }
        .main { display: flex; flex-direction: column; gap: 10px; }
        .terminal { flex: 1; background: #000; padding: 15px; overflow-y: auto; white-space: pre-wrap; font-size: 13px; border-radius: 8px; border: 1px solid #333; font-family: 'Consolas', monospace; }
        .controls { display: grid; grid-template-columns: repeat(2, 1fr); gap: 8px; }
        button, .file-btn { padding: 10px; background: #333; color: white; border: 1px solid #444; border-radius: 5px; cursor: pointer; text-align:center; transition:0.2s; }
        button:hover { background: #444; border-color: #666; }
        .btn-green { background: #198754; border-color: #198754; } .btn-green:hover { background: #157347; }
        .btn-red { background: #dc3545; border-color: #dc3545; } .btn-red:hover { background: #bb2d3b; }
        input { padding: 10px; background: #222; color: white; border: 1px solid #444; border-radius: 5px; width: 100%; box-sizing: border-box; }
        #file-list { margin-top:10px; overflow-y:auto; height: 250px; background:#111; border:1px solid #333; border-radius:5px; }
        .file-item { padding: 8px; cursor: pointer; border-bottom: 1px solid #222; font-size:12px; display:flex; align-items:center; }
        .file-item:hover { background: #222; }
        h3 { margin: 0 0 5px 0; font-size: 16px; color: #aaa; text-transform:uppercase; letter-spacing:1px; border-bottom:1px solid #333; padding-bottom:5px; }
        
        /* Mobile Layout */
        @media (max-width: 768px) {
            body { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
            .sidebar { height: auto; max-height: 300px; overflow-y: auto; }
        }
    </style>
</head>
<body>
    <div class='sidebar'>
        <h3>Server Controls</h3>
        <div class='controls'>
            <button class='btn-green' onclick="cmd('start')">START</button>
            <button class='btn-red' onclick="cmd('stop')">STOP</button>
        </div>
        
        <h3>Game Settings</h3>
        <div class='controls'>
            <button onclick="cmd('gamemode creative @a')">Creative</button>
            <button onclick="cmd('gamemode survival @a')">Survival</button>
            <button onclick="cmd('time set day')">Day</button>
            <button onclick="cmd('time set night')">Night</button>
        </div>

        <h3>Player Manager</h3>
        <input id='targetPlayer' placeholder='Player Name'>
        <div class='controls'>
            <button class='btn-red' onclick="action('ban')">Ban</button>
            <button class='btn-green' onclick="action('op')">OP</button>
            <button onclick="action('kick')">Kick</button>
            <button onclick="action('pardon')">Unban</button>
        </div>

        <h3>File Upload (Zip)</h3>
        <form action='/api/upload' method='post' enctype='multipart/form-data' style="display:flex; flex-direction:column; gap:5px;">
            <input type='file' name='file' required style="font-size:12px">
            <button type='submit' class='btn-green'>Upload & Unzip</button>
        </form>
        <div id='file-list'></div>
    </div>

    <div class='main'>
        <div class='terminal' id='term'></div>
        <div style='display:flex; gap:10px'>
            <input id='cmdInput' style='flex:1' placeholder='Type a command...' autocomplete="off">
            <button onclick='send()' class='btn-green' style="width:100px">Send</button>
        </div>
    </div>

<script src='/socket.io/socket.io.js'></script>
<script>
    const socket = io();
    const term = document.getElementById('term');
    
    // Auto-scroll logic
    let isScrolledToBottom = true;
    term.addEventListener('scroll', () => {
        isScrolledToBottom = (term.scrollHeight - term.scrollTop <= term.clientHeight + 50);
    });

    socket.on('log', msg => {
        const l = document.createElement('div');
        l.textContent = msg;
        term.appendChild(l);
        if (isScrolledToBottom) term.scrollTop = term.scrollHeight;
    });

    socket.on('history', msg => {
        term.textContent = msg;
        term.scrollTop = term.scrollHeight;
    });

    function cmd(c) { socket.emit('command', c); }
    
    function send() {
        const i = document.getElementById('cmdInput');
        if(i.value) { cmd(i.value); i.value=''; }
    }
    
    document.getElementById('cmdInput').addEventListener('keypress', (e) => {
        if (e.key === 'Enter') send();
    });

    function action(act) {
        const p = document.getElementById('targetPlayer').value;
        if(p) cmd(act + ' ' + p); 
        else alert('Please enter a player name first!');
    }

    // File Browser
    function loadFiles(path = '.') {
        fetch('/api/files?path=' + path).then(r=>r.json()).then(files => {
            const list = document.getElementById('file-list');
            list.innerHTML = '';
            files.forEach(f => {
                const item = document.createElement('div');
                item.className = 'file-item';
                item.textContent = (f.isDir ? '📁 ' : '📄 ') + f.name;
                list.appendChild(item);
            });
        });
    }
    loadFiles();
</script>
</body>
</html>
EOF

# --- 6. EXPOSE PORTS ---
EXPOSE 8080 25565

# --- 7. START ---
CMD ["node", "server.js"]
