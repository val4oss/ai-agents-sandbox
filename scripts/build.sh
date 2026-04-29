#!/bin/sh

ROOT_D="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_D="${ROOT_D}/build"
IMG_D="${ROOT_D}/image"
IMG_NAME="ai-agents-sandbox"
IMG_TAG="0.1"

VALID_AGENTS="$(grep "^AGENTS.*:= " Makefile | sed 's/.*:= //')"

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
    IMG_NAME="${IMG_NAME}-${AGENT}"
else
    AGENT="${VALID_AGENTS}"
fi

clean() {
    if [ -d "${BUILD_D}" ]; then
        echo "Cleaning previous build..."
        rm -rf "${BUILD_D}"
    fi
}

clean
mkdir -p "${BUILD_D}"
cp -r "${IMG_D}/." "${BUILD_D}/"
SCRIPT_D="${BUILD_D}/scripts"

sed -i\
    "s/AI Agents Sandbox v[0-9]\+\.[0-9]\+/AI Agents Sandbox v${IMG_TAG}/g" \
    "${SCRIPT_D}/entrypoint.sh"
sed -i\
    "s/version=\"[0-9]\+\.[0-9]\+\"/version=\"${IMG_TAG}\"/g" \
    "${BUILD_D}/Containerfile"

echo "[*] Building container image ${IMG_NAME}:${IMG_TAG}..."
if ! podman build \
    --build-arg "AGENT=${AGENT}" \
    --tag "${IMG_NAME}:${IMG_TAG}" \
    --tag "${IMG_NAME}:latest" \
    --file "${BUILD_D}/Containerfile" \
    "${BUILD_D}"; then
        echo "[✗] Image build failed."
        clean
        exit 1
fi
echo "[✓] Image Built successfully."

clean
exit 0
