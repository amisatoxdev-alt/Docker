FROM ubuntu:22.04

# 1. Setup Environment
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080 

# 2. Install Dependencies (Node 18 Fixed)
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

# Install Node.js 18 (Prevents the crash you saw earlier)
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y nodejs

# Install Java 17
RUN apt-get install -y openjdk-17-jre-headless

# 3. Install Playit.gg (The Tunnel)
RUN curl -ssL https://playit-cloud.github.io/ppa/key.gpg | gpg --dearmor | tee /etc/apt/trusted.gpg.d/playit.gpg >/dev/null \
    && echo "deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./" | tee /etc/apt/sources.list.d/playit.list \
    && apt-get update && apt-get install -y playit

# 4. Install MCSManager
WORKDIR /opt/mcsmanager
RUN wget https://github.com/MCSManager/MCSManager/releases/latest/download/mcsmanager_linux_release.tar.gz \
    && tar -zxvf mcsmanager_linux_release.tar.gz \
    && rm mcsmanager_linux_release.tar.gz \
    # Fix folder structure
    && if [ -d "mcsmanager" ]; then cp -r mcsmanager/* .; rm -rf mcsmanager; fi

# 5. Startup Script
# We start Playit in the background, then the Panel
RUN echo '#!/bin/bash\n\
echo "Starting Playit..."\n\
# Playit will print the Claim URL to the logs\n\
playit &\n\
\n\
echo "Starting MCSManager Daemon..."\n\
cd /opt/mcsmanager/daemon\n\
node app.js &\n\
\n\
echo "Starting MCSManager Web..."\n\
cd /opt/mcsmanager/web\n\
# We bind to 0.0.0.0 so Playit can find it\n\
node app.js\n\
' > /start.sh && chmod +x /start.sh

CMD ["/start.sh"]
