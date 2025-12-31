FROM dockur/windows

# --- OS CONFIGURATION ---
ENV VERSION "tiny11"
# KVM="N" is CRITICAL for Railway (Non-KVM environment)
ENV KVM "N"

# --- PERFORMANCE TUNING ---
# 16GB RAM / 8 Cores
ENV RAM_SIZE "16G"
ENV CPU_CORES "8"

# --- NETWORKING ---
# Port 8006 is the web-based viewer
EXPOSE 8006
