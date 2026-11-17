#!/bin/sh
# Glaipnir's generic host proxy wrapper
# Request read on stdin, one line per field. Each field is written as 3-digit
# octal bytes (see proxy-bin.sh): token, workspace base, cwd, tool name,
# argument count, then one line per argument.
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

set -eu
exec 2>&1

# ================
# Global variables
# ----------------

_MAX_FIELD=49152
_MAX_ARGS=1024
_FIELD=""
RECEIVED_TOKEN=""

ALLOWLIST_FILE="${GLAIPNIR_PROXY_ALLOWLIST:-}"
IS_ALLOWED=0
HOST_WORKSPACE="${GLAIPNIR_HOST_WORKSPACE:-$PWD}"

# ==================
# Internal functions
# ------------------

###
# Print the error message $1 (and the optional line $2) and the failure marker,
# then exit. The exit status is 0 on purpose: the result of a request is the
# marker line, and a socat server (1.8.0.2) loses the end of its reply when
# its child exits with a non-zero status.
# GLOBALS:
#  Read: RECEIVED_TOKEN
# ARGUMENTS:
#  1 - error message
#  2 - optional line to print
# OUTPUTS:
#  Error message, optional line and marker to stdout, then exit with code 0.
###
_fail() {
    printf '%s\n' "$1"
    if [ "$#" -gt 1 ]; then
        printf '%s\n' "$2"
    fi
    printf "__GLAIPNIR_RC_%s__:1\n" "$RECEIVED_TOKEN"
    exit 0
}

###
# Read one line from stdin and decode its octal bytes into $_FIELD.
# GLOBALS:
#   Read: _MAX_FIELD, _FIELD
# ARGUMENTS:
#   None
# OUTPUTS:
#   Sets $_FIELD to the decoded string, or fails if the line is invalid.
###
_read_field() {
    _FIELD=""
    _enc=""
    if ! IFS= read -r _enc && [ -z "$_enc" ]; then
        return 1
    fi
    case "$_enc" in
        *[!01234567]*) return 1 ;;
    esac
    [ "${#_enc}" -le "$_MAX_FIELD" ] || return 1
    [ $(( ${#_enc} % 3 )) -eq 0 ] || return 1
    _fmt="$(printf '%s\n' "$_enc" | sed 's/.../\\0&/g')"
    # Each byte must be 001-377: 000 is a NUL, 400-777 would wrap around.
    if printf '%s\n' "$_fmt" | grep -Eq '\\0([4-7]..|000)'; then
        return 1
    fi
    _dec="$(printf '%b' "${_fmt}x")"
    _FIELD="${_dec%x}"
}

# ==========
# Entrypoint
# ----------

_read_field || true
RECEIVED_TOKEN="$_FIELD"
EXPECTED_TOKEN="${GLAIPNIR_PROXY_TOKEN:-}"

if [ -z "$EXPECTED_TOKEN" ] || [ "$RECEIVED_TOKEN" != "$EXPECTED_TOKEN" ]; then
    _fail "Glaipnir Security Error: Unauthorized proxy access."
fi

_read_field || _fail "Glaipnir Proxy Error: Malformed request."
CTN_WORKSPACE_BASE="$_FIELD"
_read_field || _fail "Glaipnir Proxy Error: Malformed request."
CTN_CWD="$_FIELD"
_read_field || _fail "Glaipnir Proxy Error: Malformed request."
TOOL_NAME="$_FIELD"
_read_field || _fail "Glaipnir Proxy Error: Malformed request."
ARG_COUNT="$_FIELD"

case "$ARG_COUNT" in
    ''|*[!0123456789]*)
        _fail "Glaipnir Proxy Error: Invalid argument count."
        ;;
esac
if [ "${#ARG_COUNT}" -gt 4 ] || [ "$ARG_COUNT" -gt "$_MAX_ARGS" ]; then
    _fail "Glaipnir Proxy Error: Too many arguments."
fi

# Build the argument list in the positional parameters (no arrays in sh).
set --
_i=0
while [ "$_i" -lt "$ARG_COUNT" ]; do
    _read_field || _fail "Glaipnir Proxy Error: Malformed argument."
    set -- "$@" "$_FIELD"
    _i=$((_i + 1))
done

if [ -z "$TOOL_NAME" ]; then
    _fail "Glaipnir Proxy Error: Missing tool name."
fi
TOOL_NAME="$(basename -- "$TOOL_NAME")"

REQUESTED_CMD="$TOOL_NAME"
if [ "$#" -gt 0 ]; then
    REQUESTED_CMD="$TOOL_NAME $*"
fi

if [ -f "$ALLOWLIST_FILE" ]; then
    while IFS= read -r _entry || [ -n "$_entry" ]; do
        _trim="${_entry#"${_entry%%[![:space:]]*}"}"
        case "$_trim" in
            ''|'#'*) continue ;;
        esac

        case "$REQUESTED_CMD" in
            "$_entry" | "$_entry "*)
                IS_ALLOWED=1
                break
                ;;
        esac
    done < "$ALLOWLIST_FILE"
fi
if [ "$IS_ALLOWED" -ne 1 ]; then
    _m="Glaipnir Security Error: Command '$REQUESTED_CMD' is not"
    _fail "$_m whitelisted."
fi

# GNU realpath accepts a missing last component, BSD realpath does not: the
# directory test makes both behave the same.
REAL_BASE="$(realpath -- "$HOST_WORKSPACE" 2>/dev/null)" || REAL_BASE=""
if [ ! -d "$REAL_BASE" ]; then
    _fail "Glaipnir Error: Workspace '$HOST_WORKSPACE' not found on host."
fi

case "$CTN_CWD" in
    "$CTN_WORKSPACE_BASE"*)
        REL_PATH="${CTN_CWD#"$CTN_WORKSPACE_BASE"}"
        REL_PATH="${REL_PATH#/}"
        TARGET_DIR="${REAL_BASE}/${REL_PATH}"
        ;;
    *)
        TARGET_DIR="${REAL_BASE}"
        ;;
esac

# A missing directory and a directory outside of the workspace get the same
# answer: the agent must not learn which paths exist on the host.
REAL_TARGET="$(realpath -- "$TARGET_DIR" 2>/dev/null)" || REAL_TARGET=""
_m="Glaipnir Security Error: Directory is missing or outside of"
case "$REAL_TARGET" in
    "$REAL_BASE" | "$REAL_BASE"/*) ;;
    *) _fail "$_m the workspace." ;;
esac
if [ ! -d "$REAL_TARGET" ]; then
    _fail "$_m the workspace."
fi
cd "$REAL_TARGET"

REAL_BIN="$(command -v -- "$TOOL_NAME" 2>/dev/null || true)"
case "$REAL_BIN" in
    /*) ;;
    *) REAL_BIN="" ;;
esac
if [ -z "$REAL_BIN" ] || [ ! -x "$REAL_BIN" ]; then
    _m="Glaipnir Error: Binary '$TOOL_NAME' not found or not"
    _m="$_m executable on host."
    _fail "$_m"
fi

set +e
"$REAL_BIN" "$@" </dev/null
CMD_RC=$?

# The status of the command travels in the marker, see _fail for exit 0.
printf "__GLAIPNIR_RC_%s__:%d\n" "$RECEIVED_TOKEN" "$CMD_RC"
exit 0
