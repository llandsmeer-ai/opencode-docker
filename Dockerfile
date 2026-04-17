FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    vim \
    ca-certificates \
    curl \
    unzip \
    gnupg \
    sudo \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    cmake \
    lld \
    build-essential \
    git \
    lsof \
    clang \
    strace \
    gdb

RUN python3 -m pip install --break-system-packages \
    numpy jax scipy matplotlib

RUN usermod -aG sudo ubuntu \
    && echo "ubuntu ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

USER ubuntu

WORKDIR /home/ubuntu

RUN mkdir -p /home/ubuntu/.ssh

RUN mkdir -p /home/ubuntu/.local/share/opencode \
    && chown -R ubuntu:ubuntu /home/ubuntu/.local/share/opencode

RUN mkdir -p /home/ubuntu/.config/opencode \
    && chown -R ubuntu:ubuntu /home/ubuntu/.config/opencode

RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
RUN sh -c '. ~/.nvm/nvm.sh; nvm install 24'

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

RUN curl -fsSL https://opencode.ai/install | bash
