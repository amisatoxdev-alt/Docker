FROM ubuntu:22.04

# 1. Setup Environment
ENV DEBIAN_FRONTEND=noninteractive
# Default Railway HTTP port is usually 8080 or random, handled by script below
ENV PORT=8080 

# 2. Install Dependencies
# We install Java 17 (standard for modern MC) and Node.js
RUN apt-get update && apt-get install -y \
    openjdk-17-jre-headless \
    nodejs \
    npm \
    wget \
    curl \
    git \
    tar \
    sudo \
    net-tools \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# 3. Install MCSManager
WORKDIR /opt/mcsmanager
# Download and extract the latest release
RUN wget https://github.com/MCSManager/MCSManager/releases/latest/download/mcsmanager_linux_release.tar.gz \
    && tar -zxvf mcsmanager_linux_release.tar.gz \
    && rm mcsmanager_linux_release.tar.gz

# 4. Expose Ports
# 25565 = The port you will attach the Railway TCP Proxy to (for the game)
# 24444 = The Daemon port (internal communication)
EXPOSE 25565 24444

# 5. Startup Script
# This configures the Web Panel to use the Railway $PORT and starts both services
RUN echo '#!/bin/bash\n\
echo "Configuring MCSManager Web to listen on $PORT..."\n\
cd /opt/mcsmanager/web\n\
# Modify config.json to bind to the dynamic Railway PORT\n\
sed -i "s/\"port\": 23333/\"port\": $PORT/g" data/SystemConfig/config.json\n\
\n\
echo "Starting MCSManager Daemon..."\n\
cd /opt/mcsmanager/daemon\n\
# Start daemon in background\n\
node app.js &\n\
\n\
echo "Starting MCSManager Web..."\n\
cd /opt/mcsmanager/web\n\
# Start web panel in foreground (keeps container alive)\n\
node app.js\n\
' > /start.sh && chmod +x /start.sh

# 6. Start Command
CMD ["/start.sh"]
