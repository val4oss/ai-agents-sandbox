#!/usr/bin/env bash
# =============================================================================
# Glaipnir - Container Proxy Client Shim
# =============================================================================
set -e

PORT="${GLAIPNIR_PROXY_PORT:-}"
TOKEN="${GLAIPNIR_PROXY_TOKEN:-}"
HOST="${GLAIPNIR_PROXY_HOST:-127.0.0.1}"

if [ -z "$PORT" ] || [ -z "$TOKEN" ]; then
    echo "Glaipnir Error: Proxy configuration missing" \
        "(PORT or TOKEN not set)." >&2
    exit 1
fi

TOOL_NAME="$(basename "$0")"
WORKSPACE_DIR="${AI_WORKSPACE:-/home/aiuser/workspace}"
MARKER="__GLAIPNIR_RC_${TOKEN}__:"

USE_DEVTCP=0
if { exec 3<>/dev/tcp/"$HOST"/"$PORT"; } 2>/dev/null; then
    FD_IN=3
    FD_OUT=3
    USE_DEVTCP=1
elif command -v socat >/dev/null 2>&1; then
    coproc SOCAT { socat - "TCP:$HOST:$PORT"; }
    FD_IN="${SOCAT[0]}"
    FD_OUT="${SOCAT[1]}"
else
    echo "Glaipnir Error: Neither /dev/tcp nor 'socat' is available" \
        "in container." >&2
    exit 1
fi

printf "%s\0" "$TOKEN" "$WORKSPACE_DIR" "$PWD" "$TOOL_NAME" "$#" >&"$FD_OUT"
for arg in "$@"; do
    printf "%s\0" "$arg" >&"$FD_OUT"
done

RC=1
while IFS= read -r -u "$FD_IN" line || [ -n "$line" ]; do
    case "$line" in
        "${MARKER}"*)
            RC="${line#"${MARKER}"}"
            ;;
        *"${MARKER}"*)
            printf "%s" "${line%%"${MARKER}"*}"
            RC="${line##*"${MARKER}"}"
            ;;
        *)
            printf "%s\n" "$line"
            ;;
    esac
done

if [ "$USE_DEVTCP" -eq 1 ]; then
    exec 3<&-
    exec 3>&-
fi

exit "$RC"
