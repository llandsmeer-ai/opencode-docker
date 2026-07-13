#!/bin/bash

# Resolve the directory containing this script, following symlinks
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

IMAGE_NAME="ubuntu-claude"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"

PROJECT_DIR="project"

# Host paths that hold Claude Code auth + settings. Bind-mounting the whole
# ~/.claude directory (not just the individual files) means the OAuth token can
# be refreshed and written back atomically, keeping host and container in sync.
CLAUDE_DIR="$HOME/.claude"
CLAUDE_JSON="$HOME/.claude.json"

CONTAINER_NAME="claude-$(echo "${PWD#$HOME}" | sed 's|^/||; s|/|-|g; s|[^a-zA-Z0-9-]||g')"

# The command run inside the container. We're in a throwaway, non-root sandbox,
# so skip the per-action permission prompts.
CLAUDE_CMD="claude --dangerously-skip-permissions"

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

# Assemble the auth/settings/ssh mount flags, only including what exists on the
# host so docker doesn't auto-create empty dirs in their place.
auth_mounts() {
    local mounts=()

    # Shared Claude auth + settings (read-write so token refresh persists).
    if [ -d "$CLAUDE_DIR" ]; then
        mounts+=(-v "$CLAUDE_DIR":/home/ubuntu/.claude)
    else
        echo "⚠️  $CLAUDE_DIR not found — is Claude Code set up on the host?" >&2
    fi
    if [ -f "$CLAUDE_JSON" ]; then
        mounts+=(-v "$CLAUDE_JSON":/home/ubuntu/.claude.json)
    fi

    # Git identity (read-only).
    [ -f "$HOME/.gitconfig" ] && mounts+=(-v "$HOME/.gitconfig":/home/ubuntu/.gitconfig:ro)

    # SSH key for git over ssh (read-only), if present.
    [ -f "$HOME/.ssh/id_ed25519" ] && mounts+=(-v "$HOME/.ssh/id_ed25519":/home/ubuntu/.ssh/id_ed25519:ro)

    printf '%s\n' "${mounts[@]}"
}

show_help() {
    echo "Usage: $(basename "$0") [OPTION]"
    echo ""
    echo "Options:"
    echo "  (none)         Start or attach to the claude container for the current directory"
    echo "  --tmp [FILES]  Run standalone in a temp dir; optionally copy FILES in for context"
    echo "  --build        Build (or rebuild) the Docker image"
    echo "  rebuild        Alias for --build"
    echo "  --edit         Open the Dockerfile in \$EDITOR"
    echo "  --kill         Stop and remove all claude containers"
    echo "  --clean        Alias for --kill"
    echo "  --help, -h     Show this help message"
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

    mapfile -t MOUNTS < <(auth_mounts)

    sudo docker run -dit --name "$CONTAINER_NAME" \
        -h "claude-tmp" \
        -w /home/ubuntu/$PROJECT_DIR \
        -v "$TMP_DIR":/home/ubuntu/$PROJECT_DIR \
        "${MOUNTS[@]}" \
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
    sudo docker exec -it -w /home/ubuntu/$PROJECT_DIR "$CONTAINER_NAME" /bin/bash -c "$CLAUDE_CMD"
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

if [ "$1" == "--kill" ] || [ "$1" == "--clean" ]; then
    kill_containers
    exit 0
fi

if [ "$(sudo docker ps -q -f name=$CONTAINER_NAME)" ]; then
    echo "🔄 Container '$CONTAINER_NAME' is already running."
    echo "🔗 Connecting to Claude Code..."
    exec sudo docker exec -it -w /home/ubuntu/$PROJECT_DIR $CONTAINER_NAME /bin/bash -c "$CLAUDE_CMD"
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

mapfile -t MOUNTS < <(auth_mounts)

sudo docker run -dit --name $CONTAINER_NAME \
    -h $CONTAINER_NAME \
    -w /home/ubuntu/$PROJECT_DIR \
    -v "$(pwd)":/home/ubuntu/$PROJECT_DIR \
    "${MOUNTS[@]}" \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -e "DISPLAY=${DISPLAY}" \
    $IMAGE_NAME /bin/bash

echo "🔗 Connecting to Claude Code..."
exec sudo docker exec -it -w /home/ubuntu/$PROJECT_DIR $CONTAINER_NAME /bin/bash -c "$CLAUDE_CMD"
