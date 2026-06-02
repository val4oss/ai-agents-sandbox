#!/bin/sh
# vpn-enforcer - macOS daemon that enforces VM-layer nftables rules.
# Copyright (C) 2026  val4oss <val4oss@pm.me>
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

# Augment PATH for launchd context (does not inherit user PATH).
# Prepend common Homebrew/Podman install locations.
PATH="/opt/homebrew/bin:/usr/local/bin:\
${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
export PATH

# ================
# Global variables
# ----------------

_READY_FILE="/tmp/ai-sandbox-enforcer.ready"
_LABEL="com.ai-agents-sandbox.vpn-enforcer"

_machine=""
_ext_nic=""

# ==================
# Internal functions
# ------------------

# print an informational log line
_log_info() {
    printf '[vpn-enforcer] INFO: %s\n' "$1"
}

# print a warning log line
_log_warn() {
    printf '[vpn-enforcer] WARN: %s\n' "$1"
}

# print an error log line
_log_error() {
    printf '[vpn-enforcer] ERROR: %s\n' "$1" >&2
}

# return 0 if any VPN connection is active on macOS
_vpn_active() {
    # Method 1: macOS Network Configuration framework
    if command -v scutil > /dev/null 2>&1; then
        if scutil --nc list 2>/dev/null \
            | grep -qi 'connected'; then
            return 0
        fi
    fi

    # Method 2: utun/ppp interfaces carrying IPv4
    # System-owned utun ifaces (AirDrop, iCloud) only carry IPv6.
    for _vi in $(ifconfig -l 2>/dev/null \
        | tr ' ' '\n' \
        | grep -E '^(utun|ppp)[0-9]'); do
        if ifconfig "$_vi" 2>/dev/null \
            | grep -q 'inet [0-9]'; then
            return 0
        fi
    done

    return 1
}

# apply nftables DROP rule inside Podman Machine VM
_apply_rules() {
    podman machine ssh "${_machine}" -- \
        sudo nft delete table inet vpn-block \
        2>/dev/null || true

    # Use the output chain so that slirp4netns userspace traffic
    # is intercepted. The forward chain is not used because
    # --network slirp4netns bypasses kernel bridging entirely.
    # Established connections (e.g. SSH management) are preserved;
    # only new outbound connections on the VM NIC are dropped.
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
        'table inet vpn-block {' \
        '    chain container-egress {' \
        '        type filter hook output priority 0;' \
        '        policy accept;' \
        '        ct state established,related accept;' \
        "        oif \"${_ext_nic}\" ct state new drop;" \
        '    }' \
        '}' \
        | podman machine ssh "${_machine}" -- \
            sudo nft -f - 2>/dev/null || true

    _log_info "nftables rules applied."
}

# remove nftables rules from Podman Machine VM
_remove_rules() {
    podman machine ssh "${_machine}" -- \
        sudo nft delete table inet vpn-block \
        2>/dev/null || true
    _log_info "nftables rules removed."
}

# clean up rules and temporary files on exit
_cleanup() {
    _log_info "Shutting down..."
    _remove_rules
    rm -f "$_READY_FILE" \
        "/tmp/ai-sandbox-enforcer.state"
    exit 0
}

# wait until Podman Machine is reachable via SSH (max 10 min)
_wait_for_machine() {
    _wfm_attempt=0
    _wfm_max=60
    while [ "$_wfm_attempt" -lt "$_wfm_max" ]; do
        if podman machine ssh "${_machine}" -- \
            true 2>/dev/null; then
            return 0
        fi
        _wfm_attempt=$(( _wfm_attempt + 1 ))
        if [ "$_wfm_attempt" -eq 1 ]; then
            _log_info \
"SSH not ready for '${_machine}'."
        fi
        _log_info \
"Waiting for Machine (${_wfm_attempt}/${_wfm_max})..."
        sleep 10
    done
    _log_error \
"Machine '${_machine}' unreachable after 600s."
    exit 1
}

# discover VM interface names via SSH
_discover_interfaces() {
    _ext_nic="$(podman machine ssh "${_machine}" -- \
        ip route show default \
        | awk '/^default/{print $5; exit}')"

    if [ -z "$_ext_nic" ]; then
        _log_error "Could not discover external NIC in VM."
        exit 1
    fi

    _log_info "External NIC : ${_ext_nic}"
}

# ============
# Arg parsing
# ------------

while [ $# -gt 0 ]; do
    case "$1" in
        --machine)
            if [ -z "$2" ]; then
                _log_error "--machine requires an argument."
                exit 1
            fi
            _machine="${2%\*}"
            shift 2
            ;;
        *)
            _log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# auto-discover machine name if not provided
if [ -z "$_machine" ]; then
    _machine="$(podman machine list \
        --format '{{.Name}}' 2>/dev/null | head -1)"
    # Strip trailing '*' (default-machine marker) that
    # podman >= 5.x appends to the default machine name.
    _machine="${_machine%\*}"
    if [ -z "$_machine" ]; then
        _log_error "No Podman Machine found."
        exit 1
    fi
fi
_log_info "Using Podman Machine: ${_machine}"

# ===========
# Main script
# -----------

trap '_cleanup' TERM INT

_wait_for_machine
_discover_interfaces

# sync initial state
if _vpn_active; then
    _log_info "VPN active at startup — blocking egress."
    _apply_rules
else
    _log_info "No VPN at startup — egress allowed."
    _remove_rules
fi

touch "$_READY_FILE"
_log_info "Ready. Watching for routing changes."

# event-driven watch loop
# State is tracked via a file because route -n monitor
# is piped to while-read, which runs in a subshell where
# variable changes do not propagate to the parent.
_state_file="/tmp/ai-sandbox-enforcer.state"
if _vpn_active; then
    printf 'active' > "$_state_file"
else
    printf 'inactive' > "$_state_file"
fi

# react to a single routing change event
_handle_event() {
    _prev="$(cat "$_state_file" 2>/dev/null)"
    if _vpn_active; then _cur="active"; else _cur="inactive"; fi
    if [ "$_cur" != "$_prev" ]; then
        printf '%s' "$_cur" > "$_state_file"
        if [ "$_cur" = "active" ]; then
            _log_warn "VPN detected — blocking egress."
            _apply_rules
        else
            _log_info "VPN gone — restoring egress."
            _remove_rules
        fi
    fi
}

while :; do
    route -n monitor 2>/dev/null \
        | while IFS= read -r _line; do
            _handle_event
        done
    _log_warn "route monitor exited; restarting in 2s..."
    sleep 2
done
