#!/bin/sh
# macos-vpn-enforcer - macOS daemon that enforces VM-layer nftables rules.
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

# Augment PATH for launchd context (does not inherit user PATH).
# Prepend common Homebrew/Podman install locations.
PATH="/opt/homebrew/bin:/usr/local/bin:\
${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
export PATH

# Source macOS VPN route-discovery helpers (same directory).
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/macos-network-policy.sh
. "${_SCRIPT_DIR}/macos-network-policy.sh"

# ================
# Global variables
# ----------------

_READY_FILE="/tmp/ai-sandbox-enforcer.ready"
# Runtime config written by ai-agents-sandbox.sh before each run.
# Contains VPN_ROUTES/FALLBACK_POLICY and optional OLLAMA_IP/OLLAMA_PORT.
_CONF_FILE="/tmp/ai-sandbox-enforcer.conf"
_LABEL="com.ai-agents-sandbox.macos-vpn-enforcer"

_machine=""
_ext_nic=""

# ==================
# Internal functions
# ------------------

# print an informational log line
_log_info() {
    printf '[macos-vpn-enforcer] INFO: %s\n' "$1"
}

# print a warning log line
_log_warn() {
    printf '[macos-vpn-enforcer] WARN: %s\n' "$1"
}

# print an error log line
_log_error() {
    printf '[macos-vpn-enforcer] ERROR: %s\n' "$1" >&2
}

# apply blanket egress block — used only as fallback when no
# VPN routes can be discovered (FALLBACK_POLICY=block).
# Allows exceptions for OLLAMA_IP:OLLAMA_PORT if configured, 
# so that Ollama-hosted models can be used even with a full-tunnel 
# VPN that hides all routes.  This is a single catch-all DROP rule, 
# scoped to the VM external NIC and new connections only.  
# Established/related traffic is kept.
_apply_blanket_block() {
    _abb_ollama_ip="$1"
    _abb_ollama_port="$2"
    _abb_tmp="/tmp/ai-sandbox-nft-blanket.$$.conf"
    {
        printf 'table inet vpn-block {\n'
        printf '    chain container-egress {\n'
        printf \
            '        type filter hook output priority 0;\n'
        printf '        policy accept;\n'
        printf \
            '        ct state established,related accept;\n'
        if [ -n "$_abb_ollama_ip" ] && [ -n "$_abb_ollama_port" ]; then
            printf \
                '        ip daddr %s tcp dport %s oif "%s" ct state new accept;\n' \
                "$_abb_ollama_ip" "$_abb_ollama_port" "${_ext_nic}"
        fi
        printf \
            '        oif "%s" ct state new drop;\n' \
            "${_ext_nic}"
        printf '    }\n}\n'
    } > "$_abb_tmp"
    podman machine ssh "${_machine}" -- \
        sudo nft -f - < "$_abb_tmp" 2>/dev/null || true
    rm -f "$_abb_tmp"
}

# apply per-CIDR nftables DROP rules inside Podman Machine VM.
# Re-discovers VPN routes live, merges with config-file routes,
# and builds one DROP rule per CIDR on the VM external NIC.
# Internet-bound traffic is unaffected.
_apply_rules() {
    # Step 1: Re-discover live VPN routes from macOS routing table.
    _ar_dyn=""
    _ar_disc_ret=0
    _ar_dyn="$(_macos_discover_vpn_routes 2>/dev/null)" \
        || _ar_disc_ret=$?

    # Step 2: Read routes and policy from config.
    _ar_cfg=""
    _ar_fallback="allow"
    _ar_ollama_ip=""
    _ar_ollama_port=""
    if [ -f "$_CONF_FILE" ]; then
        _ar_r="$(sed -n 's/^VPN_ROUTES=//p' \
            "$_CONF_FILE" | head -1)"
        [ -n "$_ar_r" ] && _ar_cfg="$_ar_r"
        _ar_fp="$(sed -n 's/^FALLBACK_POLICY=//p' \
            "$_CONF_FILE" | head -1)"
        [ -n "$_ar_fp" ] && _ar_fallback="$_ar_fp"
        _ar_oip="$(sed -n 's/^OLLAMA_IP=//p' \
            "$_CONF_FILE" | head -1)"
        [ -n "$_ar_oip" ] && _ar_ollama_ip="$_ar_oip"
        _ar_opt="$(sed -n 's/^OLLAMA_PORT=//p' \
            "$_CONF_FILE" | head -1)"
        [ -n "$_ar_opt" ] && _ar_ollama_port="$_ar_opt"
    fi

    case "$_ar_ollama_port" in
        ''|*[!0-9]*)
            if [ -n "$_ar_ollama_port" ]; then
                _log_warn "Ignoring invalid OLLAMA_PORT in config."
            fi
            _ar_ollama_port=""
            ;;
    esac
    if [ -n "$_ar_ollama_port" ] && \
        { [ "$_ar_ollama_port" -lt 1 ] || [ "$_ar_ollama_port" -gt 65535 ]; }
    then
        _log_warn "Ignoring out-of-range OLLAMA_PORT in config."
        _ar_ollama_port=""
    fi
    if [ -n "$_ar_ollama_ip" ] && [ -z "$_ar_ollama_port" ]; then
        _ar_ollama_port="11434"
    fi

    # Step 3: Warn on full-tunnel (return code 1), fall back to
    # config-file routes so at least those are blocked.
    if [ "$_ar_disc_ret" -eq 1 ]; then
        _log_warn \
"Full-tunnel VPN: route discovery skipped; using config routes."
        _ar_dyn=""
    fi

    # Step 4: Merge and deduplicate routes.
    _ar_all=""
    for _r in $_ar_dyn $_ar_cfg; do
        [ -z "$_r" ] && continue
        case " ${_ar_all} " in
            *" ${_r} "*) continue ;;
        esac
        _ar_all="${_ar_all:+${_ar_all} }${_r}"
    done

    # Step 5: Remove existing table.
    podman machine ssh "${_machine}" -- \
        sudo nft delete table inet vpn-block \
        2>/dev/null || true

    # Step 6: No routes — apply fallback policy.
    if [ -z "$_ar_all" ]; then
        if [ "$_ar_fallback" = "block" ]; then
            _log_warn \
"No VPN routes found — fallback: blocking all egress."
            _apply_blanket_block "$_ar_ollama_ip" "$_ar_ollama_port"
            _log_info "Blanket block rule applied."
        else
            _log_info \
"No VPN routes found — egress unrestricted (fallback=allow)."
        fi
        return
    fi

    # Step 7: Build per-CIDR rules via a temp file piped to nft.
    # One DROP rule per CIDR, scoped to the VM external NIC and
    # new connections only.  Established/related traffic is kept.
    _ar_tmp="/tmp/ai-sandbox-nft.$$.conf"
    {
        printf 'table inet vpn-block {\n'
        printf '    chain container-egress {\n'
        printf \
            '        type filter hook output priority 0;\n'
        printf '        policy accept;\n'
        printf \
            '        ct state established,related accept;\n'
        if [ -n "$_ar_ollama_ip" ] && [ -n "$_ar_ollama_port" ]; then
            printf \
                '        ip daddr %s tcp dport %s oif "%s" ct state new accept;\n' \
                "$_ar_ollama_ip" "$_ar_ollama_port" "${_ext_nic}"
        fi
        for _cidr in $_ar_all; do
            printf \
                '        ip daddr %s oif "%s" ct state new drop;\n' \
                "$_cidr" "${_ext_nic}"
        done
        printf '    }\n}\n'
    } > "$_ar_tmp"

    if ! podman machine ssh "${_machine}" -- \
        sudo nft -f - < "$_ar_tmp" 2>/dev/null; then
        _log_error "Failed to apply nftables rules."
        rm -f "$_ar_tmp"
        return
    fi
    rm -f "$_ar_tmp"

    _log_info "Per-CIDR rules applied: ${_ar_all}"
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
if _macos_vpn_active; then
    _log_info "VPN active at startup — applying route-specific rules."
    _apply_rules
else
    _log_info "No VPN at startup — egress unrestricted."
    _remove_rules
fi

touch "$_READY_FILE"
_log_info "Ready. Watching for routing changes."

# event-driven watch loop
# State is tracked via a file because route -n monitor
# is piped to while-read, which runs in a subshell where
# variable changes do not propagate to the parent.
_state_file="/tmp/ai-sandbox-enforcer.state"
if _macos_vpn_active; then
    printf 'active' > "$_state_file"
else
    printf 'inactive' > "$_state_file"
fi

# react to a single routing change event
_handle_event() {
    _prev="$(cat "$_state_file" 2>/dev/null)"
    if _macos_vpn_active; then _cur="active"; else _cur="inactive"; fi
    printf '%s' "$_cur" > "$_state_file"
    if [ "$_cur" = "active" ]; then
        # Re-discover and re-apply on every routing event while
        # VPN is active — routes added/removed by VPN reconnects
        # are picked up automatically.
        if [ "$_prev" != "active" ]; then
            _log_warn \
"VPN detected — applying route-specific rules."
        else
            _log_info \
"Routing change — refreshing VPN block rules."
        fi
        _apply_rules
    elif [ "$_prev" = "active" ]; then
        _log_info "VPN gone — removing rules."
        _remove_rules
    fi
}

while :; do
    route -n monitor 2>/dev/null \
        | while IFS= read -r _line; do
            _handle_event
            sleep 1
        done
    _log_warn "route monitor exited; restarting in 2s..."
    sleep 2
done
