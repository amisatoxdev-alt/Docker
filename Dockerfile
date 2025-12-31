# We use ghcr.io (GitHub) instead of Docker Hub to bypass the rate limit error
FROM ghcr.io/dockur/windows:latest

# --- OS CONFIGURATION ---
ENV VERSION "tiny11"
ENV KVM "N"

# --- PERFORMANCE TUNING ---
# 16GB RAM / 8 Cores (Adjusted for your Railway plan)
ENV RAM_SIZE "16G"
ENV CPU_CORES "8"

# --- STORAGE ---
# We removed the VOLUME command because Railway forbids it in Dockerfiles.
# You MUST add the volume in the Railway Dashboard settings instead.

# --- NETWORKING ---
EXPOSE 8006
