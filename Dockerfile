FROM ubuntu:22.04

# ===============================
# 1. ENVIRONMENT
# ===============================
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080

# ===============================
# 2. SYSTEM DEPENDENCIES
# ===============================
RUN apt-get update && apt-get install -y \
    curl wget git unzip zip \
    openjdk-21-jre-headless \
    nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# ===============================
# 3. APP DIRECTORY
# ===============================
WORKDIR /app

# ===============================
# 4. NODE DEPENDENCIES
# ===============================
RUN npm init -y && npm install \
    express socket.io multer fs-extra \
    body-parser express-session adm-zip

# ===============================
# 5. DEFAULT PANEL CONFIG
# ===============================
RUN cat << 'EOF' > panel-config.json
{
  "ram": "1G",
  "cpu": 1,
  "version": "1.20.4",
  "jar": "paper.jar"
}
EOF

# ===============================
# 6. SERVER BACKEND
# ===============================
RUN cat << 'EOF' > server.js
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const { spawn, execSync } = require('child_process');
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

const CONFIG_FILE = 'panel-config.json';
const USER_FILE = 'users.json';

let mc = null;
let logs = [];

app.use(express.static('public'));
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(session({
  secret: 'mc-panel-secret',
  resave: false,
  saveUninitialized: true
}));

function auth(req,res,next){
  if(req.session.loggedin) next();
  else res.redirect('/login.html');
}

function loadConfig(){
  return fs.readJsonSync(CONFIG_FILE, {throws:false});
}

async function downloadServer(version){
  const meta = JSON.parse(execSync(
    `curl -s https://api.papermc.io/v2/projects/paper/versions/${version}`
  ));
  const build = meta.builds.at(-1);
  execSync(
    `wget -O paper.jar https://api.papermc.io/v2/projects/paper/versions/${version}/builds/${build}/downloads/paper-${version}-${build}.jar`
  );
  fs.writeFileSync('eula.txt','eula=true');
}

function startServer(){
  if(mc) return;
  const cfg = loadConfig();
  mc = spawn('java',[
    `-Xmx${cfg.ram}`,
    `-Xms${cfg.ram}`,
    '-jar','paper.jar','nogui'
  ]);
  mc.stdout.on('data',d=>{
    const t=d.toString();
    logs.push(t); if(logs.length>500) logs.shift();
    io.emit('log',t);
  });
  mc.stderr.on('data',d=>io.emit('log',d.toString()));
  mc.on('close',()=>{mc=null;io.emit('log','\\n[SERVER STOPPED]\\n');});
}

function stopServer(){
  if(mc) mc.stdin.write('stop\n');
}

function restartServer(){
  stopServer();
  setTimeout(startServer,5000);
}

app.post('/api/auth',(req,res)=>{
  const {username,password,action}=req.body;
  let users={};
  if(fs.existsSync(USER_FILE)) users=fs.readJsonSync(USER_FILE);
  if(action==='signup'){
    if(Object.keys(users).length>0) return res.json({success:false});
    users[username]=password;
    fs.writeJsonSync(USER_FILE,users);
    req.session.loggedin=true;
    return res.json({success:true});
  }
  if(users[username]===password){
    req.session.loggedin=true;
    return res.json({success:true});
  }
  res.json({success:false});
});

app.get('/api/check-setup',(req,res)=>{
  if(!fs.existsSync(USER_FILE)) return res.json({setup:true});
  const u=fs.readJsonSync(USER_FILE);
  res.json({setup:Object.keys(u).length===0});
});

app.post('/api/settings',auth,async(req,res)=>{
  const cfg=loadConfig();
  cfg.ram=req.body.ram;
  cfg.version=req.body.version;
  fs.writeJsonSync(CONFIG_FILE,cfg,{spaces:2});
  await downloadServer(cfg.version);
  restartServer();
  res.json({success:true});
});

app.post('/api/plugin',auth,upload.single('plugin'),(req,res)=>{
  fs.ensureDirSync('plugins');
  fs.moveSync(req.file.path,`plugins/${req.file.originalname}`,{overwrite:true});
  res.json({success:true});
});

io.on('connection',sock=>{
  sock.emit('history',logs.join(''));
  sock.on('command',cmd=>{
    if(cmd==='start') startServer();
    else if(cmd==='stop') stopServer();
    else if(cmd==='restart') restartServer();
    else if(mc) mc.stdin.write(cmd+'\n');
  });
});

const port=process.env.PORT||8080;
server.listen(port,()=>console.log('Panel running on',port));
EOF

# ===============================
# 7. FRONTEND
# ===============================
RUN mkdir public

RUN cat << 'EOF' > public/login.html
<!DOCTYPE html><html><body style="background:#111;color:white">
<h2>Admin Setup / Login</h2>
<input id=u placeholder=Username>
<input id=p type=password placeholder=Password>
<button onclick=go()>Submit</button>
<script>
fetch('/api/check-setup').then(r=>r.json()).then(d=>window.action=d.setup?'signup':'login');
function go(){
fetch('/api/auth',{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify({username:u.value,password:p.value,action})})
.then(r=>r.json()).then(d=>d.success?location.href='/':alert('Failed'));
}
</script></body></html>
EOF

RUN cat << 'EOF' > public/index.html
<!DOCTYPE html><html><body style="background:#111;color:#0f0">
<h2>Minecraft Panel</h2>
<button onclick="c('start')">Start</button>
<button onclick="c('stop')">Stop</button>
<button onclick="c('restart')">Restart</button><br><br>
RAM <input id=ram value="1G">
Version <input id=ver value="1.20.4">
<button onclick="save()">Save & Restart</button><br><br>
<div id=term style="white-space:pre;height:300px;overflow:auto;border:1px solid"></div>
<input id=cmd><button onclick="c(cmd.value)">Send</button>
<script src="/socket.io/socket.io.js"></script>
<script>
const s=io(),t=document.getElementById('term');
s.on('log',m=>{t.textContent+=m;t.scrollTop=t.scrollHeight});
s.on('history',m=>t.textContent=m);
function c(x){s.emit('command',x)}
function save(){
fetch('/api/settings',{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify({ram:ram.value,version:ver.value})});
}
</script></body></html>
EOF

# ===============================
# 8. PORTS
# ===============================
EXPOSE 8080 25565

# ===============================
# 9. START
# ===============================
CMD ["node","server.js"]
