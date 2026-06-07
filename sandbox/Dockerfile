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

# ── Layer 3: Rust toolchain ───────────────────────────────────────────────────
ENV RUSTUP_HOME=/root/.rustup
ENV CARGO_HOME=/root/.cargo
ENV PATH=/root/.cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --no-modify-path --default-toolchain stable \
    && rustup toolchain install nightly \
    && rustup target add wasm32-unknown-unknown

# ── Layer 4: Cargo tools ──────────────────────────────────────────────────────
# wasm-bindgen-cli must match the version pinned in Cargo.lock.
# claude.sh reads the version at runtime and passes it here as a build arg,
# so the image tag includes the version (prompt-yourself-sandbox:wbg-X.Y.Z).
# A new image is only built when the version changes.
ARG WASM_BINDGEN_VERSION
RUN cargo install just basic-http-server wasm-pack \
    && cargo install wasm-bindgen-cli --version "$WASM_BINDGEN_VERSION"

# -- Pi
# RUN curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/pi_agent_rust/main/install.sh?$(date +%s)" \
#     | bash -s -- --yes --easy-mode
# ENV PATH="$HOME/.local/bin:$PATH"
RUN npm install -g @mariozechner/pi-coding-agent && pi update

# ── Linux-native ripgrep + fd ─────────────────────────────────────────────────
# Pi bundles macOS binaries in ~/.pi/agent/bin/ which is mounted from the host.
# Pre-bake Linux-native versions here; entrypoint.sh copies them over at startup.
RUN mkdir -p /opt/pi-linux-bin && \
    curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-x86_64-unknown-linux-musl.tar.gz" | \
    tar xz -C /tmp --strip-components=1 && \
    mv /tmp/rg /opt/pi-linux-bin/rg && chmod +x /opt/pi-linux-bin/rg && \
    curl -fsSL "https://github.com/sharkdp/fd/releases/download/v10.2.0/fd-v10.2.0-x86_64-unknown-linux-gnu.tar.gz" | \
    tar xz -C /tmp --strip-components=1 && \
    mv /tmp/fd /opt/pi-linux-bin/fd && chmod +x /opt/pi-linux-bin/fd

# ── Pi packages ──────────────────────────────────────────────────────────────
RUN pi install npm:pi-cyber-ui \
    && pi install npm:pi-web-access \
    && pi install npm:pi-subagents \
    && pi install npm:@juicesharp/rpiv-todo \
    && pi install npm:@juicesharp/rpiv-ask-user-question \
    && pi install npm:pi-kanban

# ── Workspace ─────────────────────────────────────────────────────────────────
WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
