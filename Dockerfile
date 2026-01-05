FROM ubuntu:22.04

# 1. Setup Environment
ENV DEBIAN_FRONTEND=noninteractive
# Railway gives us this PORT variable automatically
ENV PORT=8080 

# 2. Install Dependencies (Nginx, Node 18, Java 17)
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

# 4. Create Nginx Configuration (Embedded in Dockerfile)
# This routes standard web traffic to the Panel, and "Socket" traffic to the Daemon.
RUN echo 'events { worker_connections 1024; } \
http { \
    map $http_upgrade $connection_upgrade { \
        default upgrade; \
        ""      close; \
    } \
    server { \
        listen 8080; \
        \
        # Route 1: The Web Panel \
        location / { \
            proxy_pass http://127.0.0.1:23333; \
            proxy_http_version 1.1; \
            proxy_set_header Upgrade $http_upgrade; \
            proxy_set_header Connection $connection_upgrade; \
            proxy_set_header Host $host; \
            proxy_set_header X-Real-IP $remote_addr; \
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; \
        } \
        \
        # Route 2: The Daemon (Fixes connection error) \
        location /socket.io/ { \
            proxy_pass http://127.0.0.1:24444; \
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
echo "Configuring Nginx to listen on Railway Port: $PORT..."\n\
# We replace "listen 8080" with the real Railway PORT dynamically\n\
sed "s/listen 8080;/listen $PORT;/g" /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf\n\
\n\
echo "Starting MCSManager Daemon..."\n\
cd /opt/mcsmanager/daemon\n\
node app.js &\n\
\n\
echo "Starting MCSManager Web..."\n\
cd /opt/mcsmanager/web\n\
node app.js &\n\
\n\
echo "Starting Nginx Proxy..."\n\
nginx -g "daemon off;"\n\
' > /start.sh && chmod +x /start.sh

CMD ["/start.sh"]
