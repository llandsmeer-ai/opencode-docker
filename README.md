# OpenCode Docker Setup

This repo contains a Dockerfile and scripts to run OpenCode inside a Docker container.

## What's in the box

- Ubuntu latest
- Python 3 with numpy, jax, scipy, matplotlib
- Node.js (via nvm)
- Rust
- OpenCode CLI
- Development tools: clang, gdb, strace, cmake, etc.

## Quick start

Build the image:
```bash
./build.sh
```

Run OpenCode:
```bash
./run.sh
```

The run script will:
1. Build the Docker image if it's not already built
2. Start a container with your current project mounted
3. Launch OpenCode in the container

## Requirements

- Docker
- sudo access (scripts use sudo for docker commands)

## Notes

- Your SSH keys are mounted read-only into the container
- Your git config is passed through
- The container shares your project directory at `/home/ubuntu/project`