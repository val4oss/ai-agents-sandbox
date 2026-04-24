#!/bin/sh

ROOT_D="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX_DIR="$ROOT_D/sandbox"
CONTAINER_NAME="ai-agents-sandbox"

usage() {
    echo "Usage: $0 [--all] [<agent>]"
    echo ""
    echo "  (no flag)  Remove the container only (auth and workspace preserved)"
    echo "  <agent>    Remove the agent-specific container (claude|copilot|gemini)"
    echo "  --all      Remove the container + all auth tokens in sandbox/home/"
    echo "             (workspace is always preserved)"
    exit 1
}

CLEAN_ALL=false
AGENT=""
for arg in "$@"; do
    case "$arg" in
        --all) CLEAN_ALL=true ;;
        claude|copilot|gemini) AGENT="$arg" ;;
        *) usage ;;
    esac
done

if [ -n "$AGENT" ]; then
    CONTAINER_NAME="${CONTAINER_NAME}-${AGENT}"
fi

# Remove container
if podman container exists "$CONTAINER_NAME"; then
    echo "[*] Stopping and removing container '$CONTAINER_NAME'..."
    podman rm -f "$CONTAINER_NAME"
    echo "[✓] Container removed."
else
    echo "[~] No container '$CONTAINER_NAME' found."
fi

if $CLEAN_ALL; then
    echo "[*] Cleaning auth tokens from sandbox/..."
    rm -rf \
        "$SANDBOX_DIR/.config/gh" \
        "$SANDBOX_DIR/.local" \
        "$SANDBOX_DIR/.gemini" \
        "$SANDBOX_DIR/.claude" \
        "$SANDBOX_DIR/.copilot" \
        "$SANDBOX_DIR/.bash_history" \
        "$SANDBOX_DIR/venv" \
        "$SANDBOX_DIR/.gitconfig" \
        "$SANDBOX_DIR/workspace"
    echo "[✓] Auth tokens removed."
fi

echo "[✓] Done."
