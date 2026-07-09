#!/bin/sh
# ollama.sh - Ollama endpoint support functions.
# Provides hostname resolution and URL parsing for Ollama integration.
# Sourced by ai-agents-sandbox.sh on all platforms.
# Copyright (C) 2026  git-ival <iramis.valentin@suse.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public
# License along with this program.
# If not, see <https://www.gnu.org/licenses/>.

# Ollama endpoint variables (shared by macOS and Linux paths)
_OLLAMA_SCHEME="http"
_OLLAMA_HOST=""
_OLLAMA_PORT="11434"
_OLLAMA_IP=""

# parse --ollama argument: normalize scheme, split host and port
_parse_OLLAMA_url() {
    _url="$1"
    _OLLAMA_SCHEME="http"
    case "$_url" in
        https://*) _OLLAMA_SCHEME="https" ;;
        http://*)  _OLLAMA_SCHEME="http" ;;
    esac
    _url="${_url#http://}"
    _url="${_url#https://}"
    _url="${_url%/}"
    case "$_url" in
        *:*)
            _OLLAMA_HOST="${_url%:*}"
            _OLLAMA_PORT="${_url##*:}"
            ;;
        *)
            _OLLAMA_HOST="$_url"
            _OLLAMA_PORT="11434"
            ;;
    esac
    if [ -z "$_OLLAMA_HOST" ]; then
        print_error "Invalid --ollama value: $1"
        print_error "  Expected: hostname:port or hostname"
        return "$FAILURE"
    fi
    case "$_OLLAMA_PORT" in
        *[!0-9]*)
            print_error \
                "Invalid --ollama port: $_OLLAMA_PORT"
            return "$FAILURE"
            ;;
    esac
    if [ "$_OLLAMA_PORT" -lt 1 ] || \
        [ "$_OLLAMA_PORT" -gt 65535 ]; then
        print_error \
            "Port out of range: $_OLLAMA_PORT (1-65535)"
        return "$FAILURE"
    fi
    return "$SUCCESS"
}

# resolve Ollama hostname to an IPv4 address; sets _OLLAMA_IP.
# On macOS, dig/host bypass mDNSResponder and cannot see VPN
# split-DNS entries. Prefer dscacheutil and python3 socket
# (both route through mDNSResponder / getaddrinfo) on macOS.
_resolve_OLLAMA_host() {
    _rhost="$1"
    _rip=""
    case "$_rhost" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*)
            _OLLAMA_IP="$_rhost"
            return "$SUCCESS"
            ;;
    esac

    if [ "$(uname -s)" = "Darwin" ]; then
        if command -v dscacheutil > /dev/null 2>&1; then
            _rip=$(dscacheutil -q host -a name "$_rhost" \
                2>/dev/null \
                | awk '/^ip_address:/{print $2; exit}')
        fi
        if [ -z "$_rip" ] && command -v python3 > /dev/null 2>&1; then
            _rip=$(python3 -c \
"import socket,sys; print(socket.gethostbyname(sys.argv[1]))" \
                "$_rhost" 2>/dev/null)
        fi
    fi

    if [ -z "$_rip" ] && command -v dig > /dev/null 2>&1; then
        _rip=$(dig +short +time=3 \
            "$_rhost" 2>/dev/null \
            | grep -E '^[0-9]+\.' | head -1)
    fi
    if [ -z "$_rip" ] && command -v host > /dev/null 2>&1; then
        _rip=$(host "$_rhost" 2>/dev/null \
            | awk '/has address/{print $NF; exit}')
    fi
    if [ -z "$_rip" ] && command -v getent > /dev/null 2>&1; then
        _rip=$(getent hosts "$_rhost" 2>/dev/null \
            | awk '{print $1; exit}')
    fi
    if [ -z "$_rip" ]; then
        print_error "Cannot resolve Ollama host: '$_rhost'"
        print_error "  -> Is your VPN connected?"
        return "$FAILURE"
    fi
    _OLLAMA_IP="$_rip"
    print_info "Resolved $_rhost -> $_rip"
    return "$SUCCESS"
}

# parse the --ollama URL and resolve the hostname to an IP
_validate_OLLAMA_endpoint() {
    if ! _parse_OLLAMA_url "$OLLAMA_URL"; then
        return "$FAILURE"
    fi
    if ! _resolve_OLLAMA_host "$_OLLAMA_HOST"; then
        return "$FAILURE"
    fi
    print_debug \
        "Ollama: ${_OLLAMA_HOST}:${_OLLAMA_PORT}" \
        "(${_OLLAMA_IP})"
    return "$SUCCESS"
}
