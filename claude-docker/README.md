# Claude Code Docker Setup

Run [Claude Code](https://claude.ai/code) inside a Docker container. Each project
directory gets its own standalone, persistent container — auth and settings are
seeded from the host on first launch — plus a batteries-included toolchain for
common programming and debugging work.

## What's in the box

- Ubuntu 24.04
- **Claude Code** CLI (native installer, same as the host)
- **Python 3** with numpy, scipy, matplotlib, pandas, requests/httpx, ipython,
  jupyter, pytest, black, ruff, mypy, playwright
- **Node.js 22 LTS** with npm, TypeScript, ts-node, yarn, pnpm
- **Rust** (rustup, stable) and **Go**
- **CUDA 13 toolkit** (`nvcc`, cuBLAS, etc.) — pairs with the GPU sharing below;
  driver libraries come from the host at runtime via the NVIDIA container toolkit
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

## Standalone, persistent per-project state

Each project directory gets its **own** isolated Claude state, so running many
containers at once never clobbers a shared `~/.claude` / `~/.claude.json`.

On **first launch** for a directory, the script seeds a private state dir from
your host config:

- **Auth** (`~/.claude/.credentials.json` OAuth token) — you're logged in, no
  re-auth inside the container
- **Settings** (`settings.json` — theme, model, hooks, enabled plugins)
- **Plugins** (agents, commands, skills, marketplaces)
- **Account/onboarding state** from `~/.claude.json` (host per-project history is
  stripped so the container starts clean)

That state lives on the host at:

```
~/.claude-docker/state/<container-name>/
```

and is bind-mounted into the container. Because it's stored on the host —
**outside** the container — it survives `docker stop`/`rm` and container deaths.
Anything Claude writes (session history, and **memories** under
`.claude/projects/<hash>/memory/`) is retained across restarts.

Use `./run.sh --reset` to wipe a directory's state and force a fresh re-seed from
the host on the next launch.

> **Note:** the OAuth token is *copied*, not shared. A token refresh inside a
> container writes back to that container's own state, not the host — so
> containers can't fight over the shared credentials. (Because refresh tokens
> rotate, a very old container may need a re-auth or `--reset` if its token has
> gone stale.)

The container's `ubuntu` user is uid/gid 1000, matching a typical Linux host, so
seeded files have the right ownership.

> Claude Code runs with `--dangerously-skip-permissions` because the container is
> an isolated sandbox. Only your current project directory (plus auth/git) is
> mounted in — the SSH key is **opt-in** via `--ssh`.

On every launch the script also bakes a few defaults into the container's state
(idempotent, host config untouched):

- **Default model: Fable** (`"model": "fable"` in the container's `settings.json`)
- **`/home/ubuntu/project` is pre-trusted** — no folder-trust dialog on start
- **The `--dangerously-skip-permissions` confirmation is pre-accepted** — Claude
  drops straight into the session

## GPU sharing

The host's **RTX PRO 6000 is shared with the container by default** (requires
the NVIDIA container toolkit). Pick a different card, or none:

```bash
./run.sh                 # shares the RTX PRO 6000
./run.sh --gpu=a2000     # shares the RTX A2000 instead
./run.sh --gpu=none      # no GPU
```

The card is looked up by name via `nvidia-smi` and passed as
`--gpus device=<uuid>`; on hosts without NVIDIA tooling (or without the
requested card) the script warns and starts without a GPU. Set
`CLAUDE_DOCKER_GPU` to change the default. Note the GPU is attached when the
container is **created** — run `./run.sh --kill` first to change it for an
existing container.

## Fast restarts & dev ergonomics

Beyond auth and memory, each container's state dir also persists:

- **Package caches** — `~/.cache` (pip/uv/go-build), `~/.npm`, and the Go
  workspace (`~/go`), so a rebuilt/restarted container doesn't re-download the world
- **Shell history** (`~/.bash_history`)
- **SSH `known_hosts`** — plus `git` is configured to auto-accept new host keys,
  so `git clone` over ssh never blocks on an interactive prompt

Other niceties:

- The **terminal tab / tmux window** is titled with the project (`🤖 <name>`) so
  parallel sessions across projects are easy to tell apart
- The container inherits the **host timezone** (`/etc/localtime`)
- Common **secrets / proxy vars** are passed through if set on the host:
  `GH_TOKEN`, `GITHUB_TOKEN`, `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`,
  `HTTP(S)_PROXY`, `NO_PROXY`
- Optional **resource caps**: set `CLAUDE_DOCKER_MEMORY` / `CLAUDE_DOCKER_CPUS`
  (e.g. `CLAUDE_DOCKER_MEMORY=8g CLAUDE_DOCKER_CPUS=4 ./run.sh`) so a runaway
  build can't starve the host

## run.sh flags

| Flag | Description |
|------|-------------|
| *(none)* | Start or attach to the claude container for the current directory |
| `--ssh` | Also mount `~/.ssh/id_ed25519` (git over ssh); **off by default** — combinable with other flags |
| `--gpu=NAME` | GPU to share: `pro6000` (**default**), `a2000` or `none` — combinable with other flags; applies at container creation |
| `--tmp [FILES]` | Run standalone in a throwaway temp dir; optionally copy `FILES` in for context |
| `--build` | Build (or rebuild) the Docker image |
| `rebuild` | Alias for `--build` |
| `--edit` | Open the Dockerfile in `$EDITOR` |
| `--list` | List running claude containers and their persistent state dirs |
| `--kill` | Stop and remove all claude containers (persistent state is kept) |
| `--clean` | Alias for `--kill` |
| `--reset` | Delete this directory's persistent state (forces a re-seed) |
| `--help`, `-h` | Show help message |

## Requirements

- Docker
- sudo access (the script uses `sudo` for docker commands)
- Claude Code set up on the host (so `~/.claude` exists to share)

## Notes

- Your git config is mounted read-only; your SSH key is only mounted with `--ssh`
- The X11 socket is passed through so non-headless Chrome can display if needed
- `run.sh` can be symlinked from anywhere; it locates the Dockerfile relative to
  its own real path
