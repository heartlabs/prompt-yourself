FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# ── Layer 1: System packages ──────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    build-essential \
    pkg-config \
    libssl-dev \
    libasound2-dev \
    curl \
    git \
    wget \
    sed \
    xvfb \
    ffmpeg \
    ca-certificates \
    gnupg \
    # --- Option B: VNC access ---
    # Uncomment to support exposing the virtual display over VNC + noVNC.
    # Also uncomment the x11vnc/websockify lines in entrypoint.sh and the
    # port mappings in claude.sh.
    # x11vnc \
    # novnc \
    # websockify \
    && rm -rf /var/lib/apt/lists/*

# ── Layer 2: Node.js (LTS) + Claude Code + Pi ─────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# -- Pi
# RUN curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/pi_agent_rust/main/install.sh?$(date +%s)" \
#     | bash -s -- --yes --easy-mode
# ENV PATH="$HOME/.local/bin:$PATH"
RUN npm install -g @mariozechner/pi-coding-agent

# ── Workspace ─────────────────────────────────────────────────────────────────
WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
