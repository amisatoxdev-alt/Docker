FROM ubuntu:22.04

# 1. Setup Environment
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080 

# 2. Install Basic Tools (curl needed for node setup)
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    tar \
    sudo \
    net-tools \
    iproute2 \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# 3. Install Node.js v18 (REQUIRED for MCSManager to fix 'node:crypto' error)
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y nodejs

# 4. Install Java 17 (For Minecraft)
RUN apt-get update && apt-get install -y openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# 5. Install MCSManager
WORKDIR /opt/mcsmanager
RUN wget https://github.com/MCSManager/MCSManager/releases/latest/download/mcsmanager_linux_release.tar.gz \
    && tar -zxvf mcsmanager_linux_release.tar.gz \
    && rm mcsmanager_linux_release.tar.gz \
    # Fix folder structure: move files from sub-folder to root if they exist
    && if [ -d "mcsmanager" ]; then cp -r mcsmanager/* .; rm -rf mcsmanager; fi

# 6. Expose Ports
EXPOSE 25565 24444

# 7. Startup Script
RUN echo '#!/bin/bash\n\
\n\
# Ensure config file exists before modification\n\
if [ -f "/opt/mcsmanager/web/data/SystemConfig/config.json" ]; then\n\
  echo "Configuring existing config.json..."\n\
  sed -i "s/\"port\": 23333/\"port\": $PORT/g" /opt/mcsmanager/web/data/SystemConfig/config.json\n\
else\n\
  echo "Warning: Config not found yet. It might generate on first run. Using default ports first."\n\
fi\n\
\n\
echo "Starting MCSManager Daemon..."\n\
cd /opt/mcsmanager/daemon\n\
node app.js &\n\
\n\
echo "Starting MCSManager Web..."\n\
cd /opt/mcsmanager/web\n\
# Force listening on the PORT variable by passing it as argument if supported, or relying on config\n\
node app.js\n\
' > /start.sh && chmod +x /start.sh

CMD ["/start.sh"]
