FROM ubuntu:22.04

# 1. Setup Environment
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080

# 2. Install Dependencies (Java for Minecraft, Node for Panel, Tools)
RUN apt-get update && apt-get install -y \
    openjdk-17-jre-headless \
    nodejs \
    npm \
    wget \
    curl \
    git \
    screen \
    nano \
    tar \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# 3. Install MCSManager (The Panel)
WORKDIR /opt/mcsmanager
RUN wget https://github.com/MCSManager/MCSManager/releases/latest/download/mcsmanager_linux_release.tar.gz \
    && tar -zxvf mcsmanager_linux_release.tar.gz \
    && rm mcsmanager_linux_release.tar.gz

# 4. Install Playit.gg (The Tunnel to let players join)
RUN curl -SSL https://playit-cloud.github.io/ppa/key.gpg | gpg --dearmor | tee /etc/apt/trusted.gpg.d/playit.gpg >/dev/null \
    && echo "deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./" | tee /etc/apt/sources.list.d/playit.list \
    && apt-get update && apt-get install -y playit

# 5. Create Startup Script
# This runs the Panel on Railway's port, and the Tunnel in the background
RUN echo '#!/bin/bash\n\
echo "Starting Playit.gg Tunnel..."\n\
# Start playit in background. You must claim the agent via the link in logs!\n\
playit &\n\
\n\
echo "Starting MCSManager..."\n\
# Configure MCSManager to listen on the PORT variable provided by Railway\n\
cd /opt/mcsmanager/web\n\
sed -i "s/23333/$PORT/g" data/SystemConfig/config.json\n\
\n\
# Start Daemon (controls the server) and Web (the UI)\n\
cd /opt/mcsmanager/daemon\n\
node app.js &\n\
cd /opt/mcsmanager/web\n\
node app.js\n\
' > /start.sh && chmod +x /start.sh

# 6. Start
CMD ["/start.sh"]
