#!/bin/sh
# Validate OpenCode bootstrap base rendering and local override merge.
# This test runs the OpenCode bootstrap script with a controlled environment and verifies that:
# - The base config is rendered correctly from the template with environment variable substitution.
# - A local override file can be merged correctly, with the expected precedence and structure.

set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/image/scripts/opencode-bootstrap.sh"

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    _expected="$1"
    _actual="$2"
    _label="$3"
    if [ "$_expected" != "$_actual" ]; then
        fail "${_label}: expected '${_expected}', got '${_actual}'"
    fi
}

assert_nonempty_file() {
    _path="$1"
    _label="$2"
    [ -s "$_path" ] || fail "${_label}: missing or empty file $_path"
}

TMP_D="$(mktemp -d)"
trap 'rm -rf "$TMP_D"' EXIT

HOME_D="${TMP_D}/home"
LOCAL_IMAGE_D="${TMP_D}/local-image"
LOCAL_HOST_D="${TMP_D}/local-host"
TEMPLATE_FILE="${TMP_D}/config.template.json"

mkdir -p "${HOME_D}" "${LOCAL_IMAGE_D}" "${LOCAL_HOST_D}"

cat > "${TEMPLATE_FILE}" << 'EOF'
{
    "$schema": "https://opencode.ai/config.json",
    "provider": {
        "google-vertex": {
            "options": {
                "projectId": "${GOOGLE_CLOUD_PROJECT}",
                "location": "${VERTEX_LOCATION}"
            }
        }
    },
    "model": "google-vertex/gemini-2.0-flash"
}
EOF

GOOGLE_CLOUD_PROJECT="proj-base" \
VERTEX_LOCATION="europe-west1" \
HOME="${HOME_D}" \
OPENCODE_LOCAL_IMAGE_DIR="${LOCAL_IMAGE_D}" \
OPENCODE_LOCAL_HOST_DIR="${LOCAL_HOST_D}" \
OPENCODE_TEMPLATE_FILE="${TEMPLATE_FILE}" \
sh "${SCRIPT_PATH}"

BASE_CFG="${HOME_D}/.config/opencode/config.json"
LEGACY_CFG="${HOME_D}/.config/opencode/opencode.json"

assert_nonempty_file "${BASE_CFG}" "base config"
assert_nonempty_file "${LEGACY_CFG}" "legacy config"

_base_project="$(jq -r '.provider["google-vertex"].options.projectId' "${BASE_CFG}")"
_base_location="$(jq -r '.provider["google-vertex"].options.location' "${BASE_CFG}")"
assert_eq "proj-base" "${_base_project}" "base projectId render"
assert_eq "europe-west1" "${_base_location}" "base location render"

mkdir -p "${LOCAL_HOST_D}/agents/opencode"
cat > "${LOCAL_HOST_D}/agents/opencode/config.local.override.json" << 'EOF'
{
    "model": "google-vertex/gemini-2.5-pro",
    "mcp": {
        "jenkins": {
            "type": "remote",
            "url": "https://${JENKINS_HOST}/mcp",
            "headers": {
                "Authorization": "Bearer ${JENKINS_TOKEN}"
            }
        }
    },
    "lsp": {
        "gopls": {
            "disabled": false,
            "command": ["gopls"]
        }
    }
}
EOF
chmod 600 "${LOCAL_HOST_D}/agents/opencode/config.local.override.json"

GOOGLE_CLOUD_PROJECT="proj-merged" \
VERTEX_LOCATION="global" \
JENKINS_HOST="jenkins.example" \
JENKINS_TOKEN="token-123" \
HOME="${HOME_D}" \
OPENCODE_LOCAL_IMAGE_DIR="${LOCAL_IMAGE_D}" \
OPENCODE_LOCAL_HOST_DIR="${LOCAL_HOST_D}" \
OPENCODE_TEMPLATE_FILE="${TEMPLATE_FILE}" \
sh "${SCRIPT_PATH}"

_merged_model="$(jq -r '.model' "${BASE_CFG}")"
_merged_project="$(jq -r '.provider["google-vertex"].options.projectId' "${BASE_CFG}")"
_mcp_url="$(jq -r '.mcp.jenkins.url' "${BASE_CFG}")"
_mcp_auth="$(jq -r '.mcp.jenkins.headers.Authorization' "${BASE_CFG}")"
_lsp_cmd="$(jq -r '.lsp.gopls.command[0]' "${BASE_CFG}")"

assert_eq "google-vertex/gemini-2.5-pro" "${_merged_model}" "model override"
assert_eq "proj-merged" "${_merged_project}" "base provider preserved"
assert_eq "https://jenkins.example/mcp" "${_mcp_url}" "mcp merge"
assert_eq "Bearer token-123" "${_mcp_auth}" "override env expansion"
assert_eq "gopls" "${_lsp_cmd}" "lsp merge"

printf '[PASS] opencode-bootstrap base render + local merge\n'
