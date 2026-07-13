# Claude Code Docker Setup

Run [Claude Code](https://claude.ai/code) inside a Docker container, with your
host auth and settings shared in and a batteries-included toolchain for common
programming and debugging work.

## What's in the box

- Ubuntu 24.04
- **Claude Code** CLI (native installer, same as the host)
- **Python 3** with numpy, scipy, matplotlib, pandas, requests/httpx, ipython,
  jupyter, pytest, black, ruff, mypy, playwright
- **Node.js 22 LTS** with npm, TypeScript, ts-node, yarn, pnpm
- **Rust** (rustup, stable) and **Go**
- **Headless Chrome** (`google-chrome-stable`) + **Playwright** with Chromium &
  Firefox browsers and all system dependencies pre-installed
- Build/debug tooling: build-essential, cmake, clang/lld, gdb, strace, ltrace,
  lsof, ripgrep, fd, jq, git, tmux, and friends

## Quick start

```bash
./run.sh
```

The script will:
1. Build the Docker image if it's not already built
2. Start a container with your current directory mounted at `/home/ubuntu/project`
3. Launch Claude Code (`claude --dangerously-skip-permissions`) inside it

## Shared auth & settings

Your host `~/.claude` directory and `~/.claude.json` are bind-mounted into the
container **read-write**, so:

- You're already logged in — no re-auth inside the container
- OAuth token refreshes persist back to the host (host and container stay in sync)
- Your `settings.json` (theme, model, etc.), agents, commands and plugins come
  along for free

The container's `ubuntu` user is uid/gid 1000, matching a typical Linux host, so
mounted files have the right ownership.

> Claude Code runs with `--dangerously-skip-permissions` because the container is
> an isolated sandbox. Only your current project directory (plus auth/git/ssh) is
> mounted in.

## run.sh flags

| Flag | Description |
|------|-------------|
| *(none)* | Start or attach to the claude container for the current directory |
| `--tmp [FILES]` | Run standalone in a throwaway temp dir; optionally copy `FILES` in for context |
| `--build` | Build (or rebuild) the Docker image |
| `rebuild` | Alias for `--build` |
| `--edit` | Open the Dockerfile in `$EDITOR` |
| `--kill` | Stop and remove all claude containers |
| `--clean` | Alias for `--kill` |
| `--help`, `-h` | Show help message |

## Requirements

- Docker
- sudo access (the script uses `sudo` for docker commands)
- Claude Code set up on the host (so `~/.claude` exists to share)

## Notes

- Your git config and `~/.ssh/id_ed25519` (if present) are mounted read-only
- The X11 socket is passed through so non-headless Chrome can display if needed
- `run.sh` can be symlinked from anywhere; it locates the Dockerfile relative to
  its own real path
