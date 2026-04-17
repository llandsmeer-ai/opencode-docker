# OpenCode Docker Setup

This repo contains a Dockerfile and a script to run OpenCode inside a Docker container.

## What's in the box

- Ubuntu latest
- Python 3 with numpy, jax, scipy, matplotlib
- Node.js (via nvm)
- Rust
- OpenCode CLI
- Development tools: clang, gdb, strace, cmake, etc.

## Quick start

Run OpenCode (builds the image automatically if not present):
```bash
./run.sh
```

The run script will:
1. Build the Docker image if it's not already built
2. Start a container with your current project mounted
3. Launch OpenCode in the container

## run.sh flags

| Flag | Description |
|------|-------------|
| *(none)* | Start or attach to the opencode container for the current directory |
| `--build` | Build (or rebuild) the Docker image |
| `rebuild` | Alias for `--build` |
| `--edit` | Open the Dockerfile in `$EDITOR` |
| `--kill` | Stop and remove all opencode containers |
| `--clean` | Alias for `--kill` |
| `--help`, `-h` | Show help message |

## Requirements

- Docker
- sudo access (scripts use sudo for docker commands)

## Notes

- Your SSH keys are mounted read-only into the container
- Your git config is passed through
- The container shares your project directory at `/home/ubuntu/project`
- `run.sh` can be symlinked from anywhere; it locates the Dockerfile relative to its own real path
