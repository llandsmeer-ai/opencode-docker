#!/bin/bash

# Configuration
IMAGE_NAME="ubuntu-opencode"
DOCKERFILE="Dockerfile"

PROJECT_DIR="project"

LOCAL_AUTH_FILE="$HOME/.local/share/opencode/auth.json"

CONTAINER_NAME="opencode-$(echo "${PWD#$HOME}" | sed 's|^/||; s|/|-|g; s|[^a-zA-Z0-9-]||g')"

# Function to handle building
build_image() {
    echo "🔨 Building image from $DOCKERFILE..."

    (
    cd /home/llandsmeer/tmp/opencode
    sudo docker build -t $IMAGE_NAME -f $DOCKERFILE .
    )

    if [ $? -ne 0 ]; then
        echo "❌ Docker build failed. Exiting."
        exit 1
    fi
    echo "✅ Build successful."
}

if [ "$1" == "rebuild" ]; then
    echo "Force rebuild requested..."
    build_image
    exit 0
fi

if [ "$(sudo docker ps -q -f name=$CONTAINER_NAME)" ]; then
    echo "🔄 Container '$CONTAINER_NAME' is already running."
    echo "🔗 Connecting to OpenCode..."
    exec sudo docker exec -it -w /home/ubuntu/$PROJECT_DIR $CONTAINER_NAME /bin/bash -c "/home/ubuntu/.opencode/bin/opencode ."
elif [ "$(sudo docker ps -aq -f name=$CONTAINER_NAME)" ]; then
    echo "🔄 Container '$CONTAINER_NAME' exists but is stopped."
    echo "🗑️  Removing old container..."
    sudo docker rm $CONTAINER_NAME
fi

# ---------------------------------------------------------
# 4. Auto-Build Image (if missing)
# ---------------------------------------------------------
if [[ "$(sudo docker images -q $IMAGE_NAME 2> /dev/null)" == "" ]]; then
    echo "⚠️  Image '$IMAGE_NAME' not found locally."
    build_image
fi

# ---------------------------------------------------------
# 5. Run New Container
# ---------------------------------------------------------
echo "🚀 Starting OpenCode..."

sudo docker run -dit --name $CONTAINER_NAME \
    -h $CONTAINER_NAME \
    -w /home/ubuntu/$PROJECT_DIR \
    -v "$(pwd)":/home/ubuntu/$PROJECT_DIR \
    -v "$HOME/.ssh/id_ed25519":/home/ubuntu/.ssh/id_ed25519:ro \
    -v "$HOME/.config/opencode":/home/ubuntu/.config/opencode \
    -v "$HOME/.gitconfig":/home/ubuntu/.gitconfig \
    -v "$LOCAL_AUTH_FILE":/home/ubuntu/.local/share/opencode/auth.json \
    -v "$LOCAL_AUTH_FILE":/home/ubuntu/.local/share/opencode/auth.json \
    $IMAGE_NAME /bin/bash

echo "🔗 Connecting to OpenCode..."
exec sudo docker exec -it -w /home/ubuntu/$PROJECT_DIR $CONTAINER_NAME /bin/bash -c "/home/ubuntu/.opencode/bin/opencode ."
