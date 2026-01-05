FROM ubuntu:22.04

# 1. Setup Environment
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080

# 2. Install Dependencies
RUN apt-get update && apt-get install -y \
    curl wget git tar sudo net-tools iproute2 \
    nginx gettext-base gnupg openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 18
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y nodejs

# 3. Install MCSManager
WORKDIR /opt/mcsmanager
RUN wget https://github.com/MCSManager/MCSManager/releases/latest/download/mcsmanager_linux_release.tar.gz \
    && tar -zxvf mcsmanager_linux_release.tar.gz \
    && rm mcsmanager_linux_release.tar.gz \
    && if [ -d "mcsmanager" ]; then cp -r mcsmanager/* .; rm -rf mcsmanager; fi

# 4. Nginx Config (Routes 443 -> Internal 20000/20001)
RUN echo 'events { worker_connections 1024; } \
http { \
    map $http_upgrade $connection_upgrade { \
        default upgrade; \
        ""      close; \
    } \
    server { \
        listen 8080; \
        location / { \
            proxy_pass http://127.0.0.1:20001; \
            proxy_http_version 1.1; \
            proxy_set_header Upgrade $http_upgrade; \
            proxy_set_header Connection $connection_upgrade; \
            proxy_set_header Host $host; \
            proxy_set_header X-Real-IP $remote_addr; \
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; \
        } \
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

EXPOSE 8080 25565

# 5. Startup Script (FORCE CONFIGURATION)
RUN echo '#!/bin/bash\n\
echo "--- CONFIGURING PORTS ---"\n\
sed "s/listen 8080;/listen $PORT;/g" /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf\n\
\n\
echo "--- STARTING DAEMON & WEB TO GENERATE FILES ---"\n\
cd /opt/mcsmanager/daemon && timeout 5s node app.js > /dev/null 2>&1\n\
cd /opt/mcsmanager/web && timeout 5s node app.js > /dev/null 2>&1\n\
\n\
echo "--- APPLYING FIXES ---"\n\
# 1. Move internal ports to 20000/20001\n\
sed -i "s/24444/20000/g" /opt/mcsmanager/daemon/data/Config/global.json\n\
sed -i "s/23333/20001/g" /opt/mcsmanager/web/data/SystemConfig/config.json\n\
\n\
echo "--- STARTING SERVICES ---"\n\
cd /opt/mcsmanager/daemon && node app.js &\n\
cd /opt/mcsmanager/web && node app.js &\n\
sleep 5\n\
nginx -g "daemon off;"\n\
' > /start.sh && chmod +x /start.sh

CMD ["/start.sh"]
