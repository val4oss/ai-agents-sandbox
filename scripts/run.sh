#!/bin/sh

SCRIPT_D="$(dirname "$0")"
ROOT_D="$(cd "${SCRIPT_D}/.." && pwd)"
SANDBOX_DIR="$ROOT_D/sandbox"
CONTAINER_NAME="ai-agents-sandbox"
IMAGE_NAME="ai-agents-sandbox"

VALID_AGENTS="$(grep "^AGENTS := " Makefile | sed 's/.*:= //')"
validate_agent() {
    _agent="$1"
    for _agt_v in $VALID_AGENTS; do
        [ "$_agent" = "$_agt_v" ] && return 0
    done
    echo "[✗] Unknown agent: '$_agent'. Valid agents: $VALID_AGENTS"
    exit 1
}

AGENT="$1"
if [ -n "$AGENT" ]; then
    validate_agent "$AGENT"
    IMAGE_NAME="${IMAGE_NAME}-${AGENT}"
    CONTAINER_NAME="${CONTAINER_NAME}-${AGENT}"
fi

# Load security defaults from containers.conf
export CONTAINERS_CONF="$SCRIPT_D/containers.conf"

# Resume a stopped container (auth state preserved)
if podman container exists "$CONTAINER_NAME"; then
    STATE=$(podman inspect "$CONTAINER_NAME" --format '{{.State.Status}}')
    if [ "$STATE" = "running" ]; then
        echo "[*] Attaching to running container..."
        podman exec -it "$CONTAINER_NAME" bash
        exit 0
    elif [ "$STATE" = "exited" ]; then
        echo "[*] Resuming existing container (auth preserved)..."
        podman start -ai "$CONTAINER_NAME"
        exit 0
    fi
fi

echo "[*] Creating isolated container..."
podman run -it \
  --name "$CONTAINER_NAME" \
  --volume "$SANDBOX_DIR":/home/aiuser:z \
  --tmpfs /tmp:rw,noexec,nosuid,size=1g \
  "${IMAGE_NAME}:latest"
