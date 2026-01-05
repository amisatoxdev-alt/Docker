FROM ubuntu:22.04

# 1. Setup Environment
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080

# 2. Install Dependencies
RUN apt-get update && apt-get install -y \
    curl wget git tar sudo net-tools iproute2 \
    nginx gettext-base gnupg openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 18 (Stability Fix)
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y nodejs

# 3. Install MCSManager
WORKDIR /opt/mcsmanager
RUN wget https://github.com/MCSManager/MCSManager/releases/latest/download/mcsmanager_linux_release.tar.gz \
    && tar -zxvf mcsmanager_linux_release.tar.gz \
    && rm mcsmanager_linux_release.tar.gz \
    && if [ -d "mcsmanager" ]; then cp -r mcsmanager/* .; rm -rf mcsmanager; fi

# 4. Create Nginx Config
# We route Traffic -> Nginx ($PORT) -> Internal Apps (20000/20001)
RUN echo 'events { worker_connections 1024; } \
http { \
    map $http_upgrade $connection_upgrade { \
        default upgrade; \
        ""      close; \
    } \
    server { \
        listen 8080; \
        \
        # Route 1: Web Panel (Internal 20001) \
        location / { \
            proxy_pass http://127.0.0.1:20001; \
            proxy_http_version 1.1; \
            proxy_set_header Upgrade $http_upgrade; \
            proxy_set_header Connection $connection_upgrade; \
            proxy_set_header Host $host; \
            proxy_set_header X-Real-IP $remote_addr; \
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; \
        } \
        \
        # Route 2: Daemon (Internal 20000) \
        location /socket.io/ { \
            proxy_pass http://127.0.0.1:20000; \
            proxy_http_version 1.1; \
            proxy_set_header Upgrade $http_upgrade; \
            proxy_set_header Connection $connection_upgrade; \
            proxy_set_header Host $host; \
            proxy_set_header X-Real-IP $remote_addr; \
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; \
        } \
    } \
}' > /etc/nginx/nginx.conf.template

# 5. Expose Ports
EXPOSE 8080 25565

# 6. Startup Script
RUN echo '#!/bin/bash\n\
\n\
echo "--- PREPARING CONFIGURATION ---"\n\
# 1. Force Nginx to use the Railway Public Port\n\
sed "s/listen 8080;/listen $PORT;/g" /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf\n\
\n\
# 2. Force Daemon to use Port 20000 (Avoids Conflict)\n\
cd /opt/mcsmanager/daemon\n\
# Run once to generate config files, then kill it\n\
timeout 5s node app.js > /dev/null 2>&1\n\
# Update the config file manually\n\
sed -i "s/24444/20000/g" data/Config/global.json\n\
\n\
# 3. Force Web Panel to use Port 20001 (Avoids Conflict)\n\
cd /opt/mcsmanager/web\n\
timeout 5s node app.js > /dev/null 2>&1\n\
sed -i "s/23333/20001/g" data/SystemConfig/config.json\n\
\n\
echo "--- STARTING SERVICES ---"\n\
# Start Daemon on 20000\n\
cd /opt/mcsmanager/daemon\n\
node app.js &\n\
\n\
# Start Web on 20001\n\
cd /opt/mcsmanager/web\n\
node app.js &\n\
\n\
# Start Nginx on Public Port\n\
echo "Starting Nginx on port $PORT..."\n\
nginx -g "daemon off;"\n\
' > /start.sh && chmod +x /start.sh

CMD ["/start.sh"]
