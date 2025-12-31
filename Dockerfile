FROM dockur/windows

# --- OS CONFIGURATION ---
ENV VERSION "tiny11"
# KVM="N" is CRITICAL for Railway. Without this, it will crash immediately.
ENV KVM "N"

# --- PERFORMANCE TUNING ---
# We give it 16GB RAM and 8 Cores (leave some room for the host overhead)
ENV RAM_SIZE "16G"
ENV CPU_CORES "8"

# --- STORAGE ---
# This tells Windows to store the disk in a specific folder we can persist later
VOLUME /storage

# --- NETWORKING ---
# Port 8006 is the web-based viewer for Windows
EXPOSE 8006
