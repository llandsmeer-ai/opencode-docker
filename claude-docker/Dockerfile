# Claude Code in a box: a self-contained dev container with the tools you
# actually reach for during a session (Python, Node/TS, Rust, Go, headless
# Chrome + Playwright). Auth and settings are shared with the host at runtime
# by bind-mounting ~/.claude and ~/.claude.json (see run.sh) -- nothing secret
# is baked into the image.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# ---------------------------------------------------------------------------
# Base system + toolchains + debugging tools
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # core
    ca-certificates curl wget gnupg lsb-release sudo locales \
    git git-lfs openssh-client \
    # editors / TUI niceties
    vim nano less tmux htop tree jq \
    # build toolchain
    build-essential cmake pkg-config clang lld \
    # search / files
    ripgrep fd-find \
    # runtime debugging
    gdb strace ltrace lsof \
    # python
    python3 python3-pip python3-venv python3-dev python3-full \
    # go (system package; fine for common use)
    golang-go \
    && rm -rf /var/lib/apt/lists/*

# fd-find installs the binary as `fdfind`; add the conventional `fd` alias
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd

# ---------------------------------------------------------------------------
# Node.js (NodeSource 22 LTS) + global JS/TS tooling
# ---------------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g npm@latest typescript ts-node yarn pnpm

# ---------------------------------------------------------------------------
# Headless Chrome (Google Chrome stable) for direct chrome-headless use
# ---------------------------------------------------------------------------
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Playwright + browsers (shared, world-readable path so any user can use them)
# Installed as root with --with-deps so all system libraries land too.
# Both the Node and Python bindings resolve browsers via PLAYWRIGHT_BROWSERS_PATH.
# ---------------------------------------------------------------------------
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g playwright @playwright/test \
    && playwright install --with-deps chromium firefox \
    && chmod -R a+rx /ms-playwright

# ---------------------------------------------------------------------------
# Python scientific / tooling stack (system-wide via --break-system-packages)
# ---------------------------------------------------------------------------
RUN python3 -m pip install --break-system-packages --no-cache-dir \
    numpy scipy matplotlib pandas \
    requests httpx \
    ipython jupyter \
    pytest black ruff mypy \
    playwright \
    && python3 -m playwright install chromium firefox

# ---------------------------------------------------------------------------
# Non-root user (uid/gid 1000 already exist as `ubuntu` in 24.04, matching a
# typical Linux host so bind-mounted files line up), passwordless sudo.
# ---------------------------------------------------------------------------
RUN usermod -aG sudo ubuntu \
    && echo "ubuntu ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

USER ubuntu
WORKDIR /home/ubuntu

# Config/state dirs. .claude and .claude.json are bind-mounted from the host
# at runtime for shared auth + settings; create them so the mounts have a home.
RUN mkdir -p /home/ubuntu/.ssh /home/ubuntu/.claude /home/ubuntu/.local/bin \
    && echo '{}' > /home/ubuntu/.claude.json

# Rust (rustup, stable toolchain) for the ubuntu user
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path

# ---------------------------------------------------------------------------
# Claude Code (native installer -> ~/.local/bin/claude, same as the host)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://claude.ai/install.sh | bash

# PATH: local bins (claude, rustup shims via cargo), plus a couple of niceties.
ENV PATH="/home/ubuntu/.local/bin:/home/ubuntu/.cargo/bin:${PATH}"

# Point Playwright at browsers Chrome ships, and let Claude Code know it's in a
# container (skips the "running as root" style warnings; we're non-root anyway).
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    IS_SANDBOX=1

# Sanity: fail the build early if the CLI didn't install cleanly.
RUN claude --version

CMD ["/bin/bash"]
