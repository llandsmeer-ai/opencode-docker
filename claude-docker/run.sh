#!/bin/bash

# Resolve the directory containing this script, following symlinks
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

IMAGE_NAME="ubuntu-claude"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"

PROJECT_DIR="project"

# Host paths that hold the *source* Claude Code auth + settings. These are only
# ever READ (to seed a per-container copy) -- never bind-mounted directly, so
# concurrent containers can't clobber each other's session state or ~/.claude.json.
CLAUDE_DIR="$HOME/.claude"
CLAUDE_JSON="$HOME/.claude.json"

# Where each container's standalone, persistent Claude state lives on the host.
# Keyed by the same path-derived name as the container, so it survives container
# death/restart and stays isolated from every other project's container.
STATE_ROOT="${CLAUDE_DOCKER_STATE:-$HOME/.claude-docker/state}"

# Optional resource caps (opt-in via env), e.g. CLAUDE_DOCKER_MEMORY=8g CLAUDE_DOCKER_CPUS=4
DOCKER_MEMORY="${CLAUDE_DOCKER_MEMORY:-}"
DOCKER_CPUS="${CLAUDE_DOCKER_CPUS:-}"

# Private SSH key is only shared into the container with an explicit --ssh flag.
SHARE_SSH=0

# GPU sharing (needs the NVIDIA container toolkit). The RTX PRO 6000 is shared
# by default; pick another card or opt out with --gpu=pro6000|a2000|none, or set
# CLAUDE_DOCKER_GPU. Applied at container *creation* — use --kill to change it
# for an existing container.
GPU_MODE="${CLAUDE_DOCKER_GPU:-pro6000}"

CONTAINER_NAME="claude-$(echo "${PWD#$HOME}" | sed 's|^/||; s|/|-|g; s|[^a-zA-Z0-9-]||g')"

# The command run inside the container. We're in a throwaway, non-root sandbox,
# so skip the per-action permission prompts.
CLAUDE_CMD="claude --dangerously-skip-permissions"

# Pull --ssh / --gpu=* out of the argument list wherever they appear; keep the
# rest intact.
ARGS=()
for a in "$@"; do
    case "$a" in
        --ssh)   SHARE_SSH=1 ;;
        --gpu=*) GPU_MODE="${a#--gpu=}" ;;
        *)       ARGS+=("$a") ;;
    esac
done
set -- "${ARGS[@]}"

case "$GPU_MODE" in
    pro6000|a2000|none) ;;
    *)
        echo "❌ Invalid --gpu value '$GPU_MODE' (expected pro6000, a2000 or none)." >&2
        exit 1
        ;;
esac

build_image() {
    echo "🔨 Building image from $DOCKERFILE..."

    (
    cd "$SCRIPT_DIR"
    sudo docker build -t $IMAGE_NAME -f $DOCKERFILE .
    )

    if [ $? -ne 0 ]; then
        echo "❌ Docker build failed. Exiting."
        exit 1
    fi
    echo "✅ Build successful."
}

kill_containers() {
    echo "Stopping and removing all claude containers..."
    CONTAINERS=$(sudo docker ps -aq --filter "ancestor=$IMAGE_NAME")
    if [ -z "$CONTAINERS" ]; then
        echo "No claude containers found."
    else
        sudo docker stop $CONTAINERS 2>/dev/null
        sudo docker rm $CONTAINERS 2>/dev/null
        echo "Done."
    fi
}

# Merge a jq filter into a JSON file ($1), creating it as {} if missing.
merge_json() {
    local file="$1" filter="$2" tmp
    [ -f "$file" ] || echo '{}' > "$file"
    if command -v jq >/dev/null 2>&1; then
        tmp="$(mktemp)"
        if jq "$filter" "$file" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$file"
        else
            rm -f "$tmp"
            echo "⚠️  Failed to update $file — leaving it as-is." >&2
        fi
    else
        echo "⚠️  jq not found — skipped applying defaults to $file." >&2
    fi
}

# Baked-in defaults for the container's Claude state ($1), applied on EVERY
# launch (idempotent, and picks up already-seeded state dirs):
#   - default model: fable
#   - the mounted project dir is pre-trusted (no trust dialog)
#   - the --dangerously-skip-permissions confirmation is pre-accepted
apply_config_defaults() {
    local state_dir="$1"

    merge_json "$state_dir/.claude/settings.json" '.model = "fable"'

    merge_json "$state_dir/.claude.json" '
        .bypassPermissionsModeAccepted = true
        | .projects["/home/ubuntu/'"$PROJECT_DIR"'"] =
            ((.projects["/home/ubuntu/'"$PROJECT_DIR"'"] // {}) + {
                hasTrustDialogAccepted: true,
                hasCompletedProjectOnboarding: true
            })'
}

# Seed a per-container Claude state directory ($1) from the host, but only on
# first launch. After seeding it is the container's own private, persistent copy:
# auth token, settings, plugins and (crucially) memories written under
# .claude/projects/<hash>/memory/ all live here and survive `docker rm`.
seed_state() {
    local state_dir="$1"
    local dest_claude="$state_dir/.claude"
    local dest_json="$state_dir/.claude.json"

    if [ -f "$state_dir/.seeded" ]; then
        apply_config_defaults "$state_dir"
        return 0
    fi

    echo "🌱 First launch for this project — seeding Claude auth + config into"
    echo "   $state_dir"
    mkdir -p "$dest_claude"

    if [ -d "$CLAUDE_DIR" ]; then
        # OAuth token (the actual auth). Copied so token refreshes inside the
        # container write back here, not to the shared host credentials.
        [ -f "$CLAUDE_DIR/.credentials.json" ] \
            && cp "$CLAUDE_DIR/.credentials.json" "$dest_claude/" \
            || echo "⚠️  No $CLAUDE_DIR/.credentials.json — container may start unauthenticated." >&2
        # User settings (theme, model, enabled plugins, hooks, permissions).
        [ -f "$CLAUDE_DIR/settings.json" ] && cp "$CLAUDE_DIR/settings.json" "$dest_claude/"
        # Plugins / marketplaces (agents, commands, skills come from here).
        [ -d "$CLAUDE_DIR/plugins" ] && cp -r "$CLAUDE_DIR/plugins" "$dest_claude/"
        # Optional user-level instructions / agents / commands, if present.
        [ -f "$CLAUDE_DIR/CLAUDE.md" ] && cp "$CLAUDE_DIR/CLAUDE.md" "$dest_claude/"
        [ -d "$CLAUDE_DIR/agents" ]   && cp -r "$CLAUDE_DIR/agents" "$dest_claude/"
        [ -d "$CLAUDE_DIR/commands" ] && cp -r "$CLAUDE_DIR/commands" "$dest_claude/"
    else
        echo "⚠️  $CLAUDE_DIR not found — is Claude Code set up on the host?" >&2
    fi

    # Seed .claude.json with the account/onboarding/cache state (so no re-login
    # or re-onboarding), but drop the host's per-project history — the container
    # builds up its own from scratch.
    if [ -f "$CLAUDE_JSON" ]; then
        if command -v jq >/dev/null 2>&1; then
            jq 'del(.projects)' "$CLAUDE_JSON" > "$dest_json" 2>/dev/null || cp "$CLAUDE_JSON" "$dest_json"
        else
            cp "$CLAUDE_JSON" "$dest_json"
        fi
    else
        echo '{}' > "$dest_json"
    fi

    apply_config_defaults "$state_dir"

    touch "$state_dir/.seeded"
}

# Assemble the mount flags for a given per-container state dir ($1):
#   - the isolated .claude / .claude.json state (read-write)
#   - persistent shell history + package caches so restarts are fast and history
#     survives container death
#   - host timezone, git identity (read-only), and — only with --ssh — the key
state_mounts() {
    local state_dir="$1"
    local mounts=()

    mounts+=(-v "$state_dir/.claude":/home/ubuntu/.claude)
    mounts+=(-v "$state_dir/.claude.json":/home/ubuntu/.claude.json)

    # Persistent caches (npm, pip/uv/go-build under ~/.cache, GOPATH) + history +
    # ssh known_hosts. Created host-side (uid 1000) so ownership lines up.
    mkdir -p "$state_dir/cache" "$state_dir/npm" "$state_dir/go" "$state_dir/ssh"
    touch "$state_dir/bash_history" "$state_dir/ssh/known_hosts"
    mounts+=(-v "$state_dir/cache":/home/ubuntu/.cache)
    mounts+=(-v "$state_dir/npm":/home/ubuntu/.npm)
    mounts+=(-v "$state_dir/go":/home/ubuntu/go)
    mounts+=(-v "$state_dir/bash_history":/home/ubuntu/.bash_history)
    mounts+=(-v "$state_dir/ssh/known_hosts":/home/ubuntu/.ssh/known_hosts)

    # Host timezone (so logs / git timestamps match), read-only.
    [ -f /etc/localtime ] && mounts+=(-v /etc/localtime:/etc/localtime:ro)

    # Git identity (read-only).
    [ -f "$HOME/.gitconfig" ] && mounts+=(-v "$HOME/.gitconfig":/home/ubuntu/.gitconfig:ro)

    # SSH key for git over ssh — ONLY with the explicit --ssh flag (read-only).
    if [ "$SHARE_SSH" -eq 1 ]; then
        if [ -f "$HOME/.ssh/id_ed25519" ]; then
            mounts+=(-v "$HOME/.ssh/id_ed25519":/home/ubuntu/.ssh/id_ed25519:ro)
        else
            echo "⚠️  --ssh given but $HOME/.ssh/id_ed25519 not found." >&2
        fi
    fi

    printf '%s\n' "${mounts[@]}"
}

# Resolve $GPU_MODE to `--gpus device=<uuid>` flags by matching the card's name
# in nvidia-smi. Degrades to no GPU (with a warning) on hosts without NVIDIA
# tooling or without the requested card, so the script still works everywhere.
gpu_run_opts() {
    [ "$GPU_MODE" == "none" ] && return 0

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "⚠️  --gpu=$GPU_MODE requested but nvidia-smi not found — starting without GPU." >&2
        return 0
    fi

    local pattern
    case "$GPU_MODE" in
        pro6000) pattern='pro *6000' ;;
        a2000)   pattern='a2000' ;;
    esac

    local uuid
    uuid="$(nvidia-smi --query-gpu=name,uuid --format=csv,noheader 2>/dev/null \
        | grep -iE "$pattern" | head -n1 | awk -F', ' '{print $NF}')"

    if [ -z "$uuid" ]; then
        echo "⚠️  No GPU matching '$GPU_MODE' found on this host — starting without GPU." >&2
        return 0
    fi

    printf '%s\n' --gpus "device=$uuid"
}

# Extra `docker run` flags: GPU sharing, opt-in resource caps, host env
# passthrough (tokens, proxies), and a git-over-ssh command that won't block on
# host-key prompts.
extra_run_opts() {
    local opts=()

    mapfile -t opts < <(gpu_run_opts)

    [ -n "$DOCKER_MEMORY" ] && opts+=(--memory "$DOCKER_MEMORY")
    [ -n "$DOCKER_CPUS" ]   && opts+=(--cpus "$DOCKER_CPUS")

    # Pass through common dev secrets / proxy settings if they exist on the host.
    local v
    for v in GH_TOKEN GITHUB_TOKEN ANTHROPIC_API_KEY ANTHROPIC_BASE_URL \
             HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy TZ; do
        [ -n "${!v}" ] && opts+=(-e "$v=${!v}")
    done

    # Accept new host keys automatically and persist them to the mounted file.
    opts+=(-e "GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/home/ubuntu/.ssh/known_hosts")

    printf '%s\n' "${opts[@]}"
}

# Attach to Claude in $1, labelling the terminal tab / tmux window with the
# project so many parallel sessions are tellable apart. tmux's automatic window
# renaming is restored afterwards.
connect_claude() {
    local container="$1"
    local title="🤖 ${container#claude-}"
    local restore=""

    # Terminal tab / window title (OSC).
    printf '\033]0;%s\007' "$title"
    if [ -n "$TMUX" ]; then
        tmux rename-window "$title" 2>/dev/null && restore=1
    fi

    sudo docker exec -it -w /home/ubuntu/$PROJECT_DIR "$container" /bin/bash -c "$CLAUDE_CMD"
    local rc=$?

    [ -n "$restore" ] && tmux set-window-option automatic-rename on 2>/dev/null
    return $rc
}

show_help() {
    echo "Usage: $(basename "$0") [OPTION] [--ssh] [--gpu=pro6000|a2000|none]"
    echo ""
    echo "Each project directory gets its own standalone, persistent Claude"
    echo "container state (auth + settings + memories + caches), seeded from the"
    echo "host on first launch and stored under:"
    echo "  $STATE_ROOT/<container-name>"
    echo ""
    echo "Options:"
    echo "  (none)         Start or attach to the claude container for the current directory"
    echo "  --ssh          Also mount ~/.ssh/id_ed25519 (git over ssh); off by default"
    echo "  --gpu=NAME     Share a GPU with the container: pro6000 (default), a2000"
    echo "                 or none. Applies when the container is created; use"
    echo "                 --kill first to change it for an existing container."
    echo "  --tmp [FILES]  Run standalone in a temp dir; optionally copy FILES in for context"
    echo "  --build        Build (or rebuild) the Docker image"
    echo "  rebuild        Alias for --build"
    echo "  --edit         Open the Dockerfile in \$EDITOR"
    echo "  --list         List running claude containers and their persistent state dirs"
    echo "  --kill         Stop and remove all claude containers (state is kept)"
    echo "  --clean        Alias for --kill"
    echo "  --reset        Delete this directory's persistent state (forces a re-seed)"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "Env: CLAUDE_DOCKER_MEMORY / CLAUDE_DOCKER_CPUS cap container resources;"
    echo "     CLAUDE_DOCKER_GPU sets the default GPU (pro6000/a2000/none);"
    echo "     GH_TOKEN / GITHUB_TOKEN / ANTHROPIC_API_KEY / *_PROXY are passed through."
}

if [ "$1" == "--tmp" ]; then
    shift

    # Create a unique subdirectory so multiple --tmp sessions don't collide
    SESSION_ID="$(date +%s)-$$"
    TMP_DIR="/tmp/claude-docker/$SESSION_ID"
    mkdir -p "$TMP_DIR"

    # Copy any provided files/dirs into the session directory
    for f in "$@"; do
        cp -r "$f" "$TMP_DIR/" 2>/dev/null
    done

    CONTAINER_NAME="claude-tmp-$SESSION_ID"

    if [[ "$(sudo docker images -q $IMAGE_NAME 2> /dev/null)" == "" ]]; then
        echo "⚠️  Image '$IMAGE_NAME' not found locally."
        build_image
    fi

    echo "🚀 Starting Claude Code in tmp mode (session $SESSION_ID)..."

    # Throwaway, isolated state seeded into the session dir (cleaned up on exit).
    STATE_DIR="$TMP_DIR/.claude-state"
    seed_state "$STATE_DIR"
    mapfile -t MOUNTS < <(state_mounts "$STATE_DIR")
    mapfile -t RUN_OPTS < <(extra_run_opts)

    sudo docker run -dit --name "$CONTAINER_NAME" \
        -h "claude-tmp" \
        -w /home/ubuntu/$PROJECT_DIR \
        -v "$TMP_DIR":/home/ubuntu/$PROJECT_DIR \
        "${MOUNTS[@]}" \
        "${RUN_OPTS[@]}" \
        $IMAGE_NAME /bin/bash

    cleanup() {
        echo "🧹 Cleaning up tmp session $SESSION_ID..."
        sudo docker stop "$CONTAINER_NAME" 2>/dev/null
        sudo docker rm "$CONTAINER_NAME" 2>/dev/null
        rm -rf "$TMP_DIR"
        # Remove parent dir if empty (no other sessions running)
        rmdir /tmp/claude-docker 2>/dev/null
    }
    trap cleanup EXIT

    echo "🔗 Connecting to Claude Code..."
    connect_claude "$CONTAINER_NAME"
    exit $?
fi

if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    show_help
    exit 0
fi

if [ "$1" == "--build" ] || [ "$1" == "rebuild" ]; then
    echo "Building image..."
    build_image
    exit 0
fi

if [ "$1" == "--edit" ]; then
    ${EDITOR:-vi} "$DOCKERFILE"
    exit 0
fi

if [ "$1" == "--list" ]; then
    echo "Running claude containers:"
    sudo docker ps --filter "ancestor=$IMAGE_NAME" --format '  {{.Names}}\t{{.Status}}' 2>/dev/null
    echo "Persistent state dirs ($STATE_ROOT):"
    if [ -d "$STATE_ROOT" ]; then
        ls -1 "$STATE_ROOT" 2>/dev/null | sed 's/^/  /'
    else
        echo "  (none yet)"
    fi
    exit 0
fi

if [ "$1" == "--kill" ] || [ "$1" == "--clean" ]; then
    kill_containers
    exit 0
fi

if [ "$1" == "--reset" ]; then
    STATE_DIR="$STATE_ROOT/$CONTAINER_NAME"
    if [ -d "$STATE_DIR" ]; then
        echo "🗑️  Removing persistent state for this directory:"
        echo "   $STATE_DIR"
        rm -rf "$STATE_DIR"
        echo "Done — next launch will re-seed from the host."
    else
        echo "No persistent state found at $STATE_DIR."
    fi
    exit 0
fi

# Per-directory persistent state, seeded on first launch.
STATE_DIR="$STATE_ROOT/$CONTAINER_NAME"
seed_state "$STATE_DIR"

if [ "$(sudo docker ps -q -f name=$CONTAINER_NAME)" ]; then
    echo "🔄 Container '$CONTAINER_NAME' is already running."
    echo "🔗 Connecting to Claude Code..."
    connect_claude "$CONTAINER_NAME"
    exit $?
elif [ "$(sudo docker ps -aq -f name=$CONTAINER_NAME)" ]; then
    echo "🔄 Container '$CONTAINER_NAME' exists but is stopped."
    echo "🗑️  Removing old container..."
    sudo docker rm $CONTAINER_NAME
fi

if [[ "$(sudo docker images -q $IMAGE_NAME 2> /dev/null)" == "" ]]; then
    echo "⚠️  Image '$IMAGE_NAME' not found locally."
    build_image
fi

echo "🚀 Starting Claude Code..."

# Allow the container to talk to the host X server (for non-headless Chrome, etc.)
xhost +local:docker >/dev/null 2>&1

mapfile -t MOUNTS < <(state_mounts "$STATE_DIR")
mapfile -t RUN_OPTS < <(extra_run_opts)

sudo docker run -dit --name $CONTAINER_NAME \
    -h $CONTAINER_NAME \
    -w /home/ubuntu/$PROJECT_DIR \
    -v "$(pwd)":/home/ubuntu/$PROJECT_DIR \
    "${MOUNTS[@]}" \
    "${RUN_OPTS[@]}" \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -e "DISPLAY=${DISPLAY}" \
    $IMAGE_NAME /bin/bash

echo "🔗 Connecting to Claude Code..."
connect_claude "$CONTAINER_NAME"
exit $?
