FROM ubuntu:22.04

# 1. Setup Environment
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080 

# 2. Install Dependencies
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

# 3. Install MCSManager (FIXED)
WORKDIR /opt/mcsmanager
RUN wget https://github.com/MCSManager/MCSManager/releases/latest/download/mcsmanager_linux_release.tar.gz \
    && tar -zxvf mcsmanager_linux_release.tar.gz \
    && rm mcsmanager_linux_release.tar.gz \
    # FIX: Move files from the sub-folder to the current directory if needed
    && if [ -d "mcsmanager" ]; then mv mcsmanager/* .; rmdir mcsmanager; fi \
    # Verify structure exists (for debugging)
    && ls -R /opt/mcsmanager

# 4. Expose Ports
EXPOSE 25565 24444

# 5. Startup Script
RUN echo '#!/bin/bash\n\
\n\
# Check if directories actually exist before starting\n\
if [ ! -d "/opt/mcsmanager/web" ]; then\n\
  echo "ERROR: /opt/mcsmanager/web not found. Listing /opt/mcsmanager:"\n\
  ls -R /opt/mcsmanager\n\
  exit 1\n\
fi\n\
\n\
echo "Configuring MCSManager Web to listen on $PORT..."\n\
cd /opt/mcsmanager/web\n\
sed -i "s/\"port\": 23333/\"port\": $PORT/g" data/SystemConfig/config.json\n\
\n\
echo "Starting MCSManager Daemon..."\n\
cd /opt/mcsmanager/daemon\n\
node app.js &\n\
\n\
echo "Starting MCSManager Web..."\n\
cd /opt/mcsmanager/web\n\
node app.js\n\
' > /start.sh && chmod +x /start.sh

# 6. Start Command
CMD ["/start.sh"]
