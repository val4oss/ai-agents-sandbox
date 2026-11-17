#!/bin/sh
# Glaipnir's container proxy client shim
# Each request field is sent as one line of 3-digit octal bytes.
# Copyright (C) 2026  val4oss <val4oss@pm.me>
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

set -e

# ================
# Global variables
# ----------------

PORT="${GLAIPNIR_PROXY_PORT:-}"
TOKEN="${GLAIPNIR_PROXY_TOKEN:-}"
HOST="${GLAIPNIR_PROXY_HOST:-127.0.0.1}"

TOOL_NAME="$(basename -- "$0")"
WORKSPACE_DIR="${AI_WORKSPACE:-/home/aiuser/workspace}"
MARKER="__GLAIPNIR_RC_${TOKEN}__:"
FIFO_D=""


# ==================
# Internal functions
# ------------------

###
# Encode the string $1 as one line of 3-digit octal bytes.
# ARGUMENTS:
#   1 - string to encode
# OUTPUTS:
#   Encoded string
###
_encode_field() {
    printf '%s' "$1" | od -An -v -to1 | tr -d '[:space:]'
    printf '\n'
}

###
# Send the encoded request: token, workspace, cwd, tool, arg count, then each
# arg.
# GLOBALS:
#   Read: TOKEN, WORKSPACE_DIR, PWD, TOOL_NAME
# ARGUMENTS:
#   @ - arguments of the command
# OUTPUTS:
#   Encoded request
###
_send_request() {
    _encode_field "$TOKEN"
    _encode_field "$WORKSPACE_DIR"
    _encode_field "$PWD"
    _encode_field "$TOOL_NAME"
    _encode_field "$#"
    for _arg in "$@"; do
        _encode_field "$_arg"
    done
}

###
# Relay the host output and return the exit code sent by the wrapper.
# GLOBALS:
#   Read: MARKER
###
_read_response() {
    _rc=1
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            "${MARKER}"*)
                _rc="${_line#"${MARKER}"}"
                ;;
            *"${MARKER}"*)
                printf "%s" "${_line%%"${MARKER}"*}"
                _rc="${_line##*"${MARKER}"}"
                ;;
            *)
                printf "%s\n" "$_line"
                ;;
        esac
    done
    return "$_rc"
}

###
# Remove the temporary directory of the request FIFO.
# GLOBALS:
#   Read: FIFO_D
###
# shellcheck disable=SC2317,SC2329 # called by the trap
_cleanup() {
    if [ -n "$FIFO_D" ]; then
        rm -rf "$FIFO_D"
    fi
}

# ==========
# Entrypoint
# ----------

if [ -z "$PORT" ] || [ -z "$TOKEN" ]; then
    echo "Glaipnir Error: Proxy configuration missing" \
        "(PORT or TOKEN not set)." >&2
    exit 1
fi

if ! command -v socat >/dev/null 2>&1; then
    echo "Glaipnir Error: 'socat' is not available in container." >&2
    exit 1
fi

# The request goes through a FIFO that this script keeps open until the reply
# is complete. socat then never half-closes the connection, which would cut the
# reply of a slow command, and nothing depends on a socat version specific
# option ("ignoreeof" is unreliable, a big "-t" makes socat wait for it).
# "-t 0": nothing is left to send once the host closed the connection.
FIFO_D="$(mktemp -d)" || {
    echo "Glaipnir Error: Cannot create a temporary directory." >&2
    exit 1
}
trap '_cleanup' EXIT
trap 'exit 1' INT TERM HUP
mkfifo "${FIFO_D}/request"
exec 4<>"${FIFO_D}/request"

# In the background: a big request would block it before socat reads.
_send_request "$@" >&4 &

_status=0
socat -t 0 - "TCP:${HOST}:${PORT}" <&4 | _read_response || _status=$?
exit "$_status"
