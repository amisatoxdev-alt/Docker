# Use the latest Ubuntu image
FROM ubuntu:latest

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080

# 1. Update and install essential networking and shell tools
RUN apt-get update && apt-get install -y \
    bash \
    curl \
    wget \
    git \
    net-tools \
    iputils-ping \
    socat \
    nmap \
    nano \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# 2. Install ttyd (Web Terminal) to access the shell via browser
RUN curl -L https://github.com/tsl0922/ttyd/releases/download/1.7.3/ttyd.x86_64 -o /usr/bin/ttyd \
    && chmod +x /usr/bin/ttyd

# 3. Create a generic user (optional, but safer) or stick to root
WORKDIR /root

# 4. EXPOSE ALL PORTS
# Note: This updates the Docker metadata to say all ports are listening.
# Railway's router will still only forward public HTTP traffic to the $PORT defined below.
EXPOSE 1-65535

# 5. Start the Web Shell
# We bind ttyd to the internal $PORT so you can access it via the Railway URL.
# 'bash' is the shell that will open.
CMD ttyd -p $PORT -W bash
