#!/bin/sh
# macos-sandbox.sh - macOS-specific VPN enforcement helpers.
# Sourced by glaipnir.sh on Darwin only.
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

# Source macOS-specific VPN route-discovery helpers.
# Provides: _macos_vpn_active, _macos_route_to_cidr,
#           _macos_discover_vpn_routes.
. "${ROOT_D}/scripts/macos-network-policy.sh"

# ===========================
# macOS VPN enforcement config
# ---------------------------

# macOS VPN enforcement config file path
_ENFORCER_CONF="/tmp/ai-sandbox-enforcer.conf"

# ===========================
# macOS-specific helpers
# ---------------------------

# apply sed replacement and atomically update a file
_sed_inplace() {
    _expr="$1"
    _target="$2"
    _tmp="${_target}.tmp.$$"
    _ret="$SUCCESS"

    if ! sed "$_expr" "$_target" > "$_tmp" \
        || ! mv "$_tmp" "$_target"; then
        _ret="$FAILURE"
    fi

    rm -f "$_tmp"
    return "$_ret"
}

# Evaluate macOS VPN state and write the enforcer config file.
# Handles three cases interactively before the enforcer starts:
#  - Split-tunnel VPN: discovers routes, writes them to config.
#  - Full-tunnel VPN: prompts user to configure split-tunnel, fails.
#  - VPN active but no routes: warns user, offers block-all or allow.
# When no VPN is active, writes an empty config (unrestricted egress).
_handle_macos_vpn_state() {
    _macos_routes=""
    _macos_fallback="allow"

    if ! _macos_vpn_active; then
        _macos_write_enforcer_config "" "allow"
        return "$SUCCESS"
    fi

    # VPN is active — discover split-tunnel routes.
    _macos_disc="$(_macos_discover_vpn_routes 2>/dev/null)"
    _macos_ret=$?

    case "$_macos_ret" in
        1)
            # Full-tunnel: default route goes through VPN.
            print_error \
"Full-tunnel VPN detected (default route via VPN interface)."
            print_error \
"  The container's internet traffic would be routed through"
            print_error \
"  your VPN, leaking your corporate identity to the AI agent."
            print_error ""
            print_error "  Configure your VPN for split-tunnel mode:"
            print_error \
"  Route only internal subnets through the VPN and keep"
            print_error \
"  internet traffic on your local network interface."
            return "$FAILURE"
            ;;
        2)
            # VPN active but no specific routes found.
            print_warning \
"VPN is active but no internal routes could be discovered."
            print_warning \
"  Cannot determine which destinations to block automatically."
            printf '\n'
            printf \
'  Choose how to proceed:\n'
            printf \
'  (a) Allow full internet access  [less secure]\n'
            printf \
'  (b) Block all egress and abort  [safer, disable VPN first]\n'
            printf 'Choice [a/b, default b]: '
            read -r _macos_choice 2>/dev/null
            case "$_macos_choice" in
                a|A)
                    print_warning \
"Proceeding with unrestricted egress (no VPN routes blocked)."
                    _macos_fallback="allow"
                    ;;
                *)
                    print_error \
"Aborting. Disable VPN or configure split-tunnel and retry."
                    return "$FAILURE"
                    ;;
            esac
            ;;
        0)
            # Split-tunnel routes discovered.
            _macos_routes="$_macos_disc"
            print_info \
"VPN split-tunnel detected — will block: ${_macos_routes}"
            ;;
    esac

    _macos_write_enforcer_config "$_macos_routes" "$_macos_fallback"
    return "$SUCCESS"
}

# write enforcer config file consumed by macos-vpn-enforcer.sh daemon.
# $1 = space-separated VPN CIDRs to block (may be empty).
# $2 = fallback policy: "allow" (default) or "block".
_macos_write_enforcer_config() {
    _wec_routes="$1"
    _wec_fallback="${2:-allow}"
    printf 'VPN_ROUTES=%s\n' \
        "$_wec_routes" > "$_ENFORCER_CONF"
    printf 'FALLBACK_POLICY=%s\n' \
        "$_wec_fallback" >> "$_ENFORCER_CONF"
    print_debug "Enforcer config: $_ENFORCER_CONF"
    return "$SUCCESS"
}

# ensure the macOS VPN enforcer is provisioned; installs if absent
_macos_ensure_enforcer() {
    _plist_dst="$HOME/Library/LaunchAgents/"
    _plist_dst="${_plist_dst}com.ai-agents-sandbox.macos-vpn-enforcer.plist"
    _log_dir="$HOME/Library/Logs/ai-agents-sandbox"
    _bin_dir="$HOME/.local/bin"
    _script_src="$ROOT_D/scripts/macos-vpn-enforcer.sh"
    _script_dst="$_bin_dir/ai-sandbox-macos-vpn-enforcer"
    _plist_tmpl="$ROOT_D/launchd/"
    _plist_tmpl="${_plist_tmpl}com.ai-agents-sandbox."
    _plist_tmpl="${_plist_tmpl}macos-vpn-enforcer.plist.template"

    if [ ! -f "$_script_src" ]; then
        print_error "macos-vpn-enforcer.sh not found: $_script_src"
        return "$FAILURE"
    fi
    if [ ! -f "$_plist_tmpl" ]; then
        print_error "Plist template not found: $_plist_tmpl"
        return "$FAILURE"
    fi

    _policy_src="$ROOT_D/scripts/macos-network-policy.sh"
    _policy_dst="$_bin_dir/macos-network-policy.sh"
    if [ ! -f "$_policy_src" ]; then
        print_error \
            "macos-network-policy.sh not found: $_policy_src"
        return "$FAILURE"
    fi

    mkdir -p "$_log_dir" "$_bin_dir" "$HOME/Library/LaunchAgents"
    cp "$_script_src" "$_script_dst"
    chmod 755 "$_script_dst"
    cp "$_policy_src" "$_policy_dst"
    chmod 644 "$_policy_dst"

    print_info "Refreshing VPN enforcer LaunchAgent for macOS..."

    launchctl stop \
        "com.ai-agents-sandbox.macos-vpn-enforcer" 2>/dev/null \
        || true
    launchctl unload "$_plist_dst" 2>/dev/null || true

    cp "$_plist_tmpl" "$_plist_dst"
    if ! _sed_inplace \
        "s|{{SCRIPT_PATH}}|${_script_dst}|g" "$_plist_dst"; then
        print_error "Failed to update plist SCRIPT_PATH."
        return "$FAILURE"
    fi
    if ! _sed_inplace \
        "s|{{LOG_DIR}}|${_log_dir}|g" "$_plist_dst"; then
        print_error "Failed to update plist LOG_DIR."
        return "$FAILURE"
    fi

    # Inject runtime PATH so launchd can find podman.
    # launchd does not inherit the user's shell PATH.
    _podman_bin="$(command -v podman 2>/dev/null)"
    [ -n "$_podman_bin" ] &&\
        _podman_dir="$(dirname "$_podman_bin" 2>/dev/null)"
    if [ -n "$_podman_dir" ]; then
        _plist_path="${_podman_dir}:/opt/homebrew/bin"
    else
        _plist_path="/opt/homebrew/bin"
    fi
    _plist_path="${_plist_path}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if ! _sed_inplace "s|{{HOME}}|${HOME}|g" "$_plist_dst"; then
        print_error "Failed to update plist HOME."
        return "$FAILURE"
    fi
    if ! _sed_inplace "s|{{PATH}}|${_plist_path}|g" "$_plist_dst"; then
        print_error "Failed to update plist PATH."
        return "$FAILURE"
    fi

    _launch_domain="gui/$(id -u)"
    if ! launchctl bootstrap \
        "$_launch_domain" "$_plist_dst" 2>/dev/null; then
        # Fallback for older launchctl variants.
        if ! launchctl load "$_plist_dst" 2>/dev/null; then
            print_error "Failed to load VPN enforcer LaunchAgent."
            return "$FAILURE"
        fi
    fi

    if ! launchctl print \
        "${_launch_domain}/com.ai-agents-sandbox.macos-vpn-enforcer" \
        >/dev/null 2>&1; then
        print_error "VPN enforcer LaunchAgent is not loaded."
        return "$FAILURE"
    fi

    print_info "VPN enforcer LaunchAgent ready."
    return "$SUCCESS"
}

# remove the macOS VPN enforcer LaunchAgent and nftables rules
_macos_remove_enforcer() {
    _plist_dst="$HOME/Library/LaunchAgents/"
    _plist_dst="${_plist_dst}com.ai-agents-sandbox.macos-vpn-enforcer.plist"
    _script_dst="$HOME/.local/bin/ai-sandbox-macos-vpn-enforcer"
    [ -f "$_plist_dst" ] || return "$SUCCESS"

    launchctl stop \
        "com.ai-agents-sandbox.macos-vpn-enforcer" 2>/dev/null \
        || true
    launchctl unload "$_plist_dst" 2>/dev/null || true

    if podman machine ssh -- true 2>/dev/null; then
        podman machine ssh -- \
            sudo nft delete table inet vpn-block 2>/dev/null \
            || true
    fi

    rm -f "$_plist_dst" "$_script_dst" \
        "$HOME/.local/bin/macos-network-policy.sh"
    print_info "VPN enforcer removed."
}

# start the VPN enforcer daemon via launchctl
_macos_start_enforcer() {
    _label="com.ai-agents-sandbox.macos-vpn-enforcer"
    _service="gui/$(id -u)/${_label}"
    _attempt=0
    _max_attempts=15

    launchctl stop "$_label" 2>/dev/null || true
    while [ "$_attempt" -lt "$_max_attempts" ]; do
        if ! launchctl print "$_service" 2>/dev/null \
            | grep -q 'state = running'; then
            break
        fi
        _attempt=$(( _attempt + 1 ))
        sleep 1
    done
    if [ "$_attempt" -ge "$_max_attempts" ]; then
        print_error "Previous VPN enforcer instance did not stop."
        return "$FAILURE"
    fi

    rm -f "/tmp/ai-sandbox-enforcer.ready" \
        "/tmp/ai-sandbox-enforcer.state"

    if ! launchctl print "$_service" >/dev/null 2>&1; then
        print_error \
            "VPN enforcer LaunchAgent is not loaded: $_service"
        print_error \
            "Run action will not continue without VPN enforcement."
        return "$FAILURE"
    fi

    # launchd imposes a minimum-runtime throttle. Retry the start
    # command until the service is running or 15 attempts expire.
    _attempt=0
    while [ "$_attempt" -lt "$_max_attempts" ]; do
        launchctl start "$_label" 2>/dev/null || true
        _st="$(launchctl print "$_service" 2>/dev/null \
            | awk '/state =/{print $3}')"
        if [ "$_st" = "running" ]; then
            return "$SUCCESS"
        fi
        _attempt=$(( _attempt + 1 ))
        sleep 1
    done
    print_error "VPN enforcer failed to start (launchd throttle)."
    return "$FAILURE"
}

# stop the VPN enforcer daemon via launchctl
_macos_stop_enforcer() {
    launchctl stop \
        "com.ai-agents-sandbox.macos-vpn-enforcer" 2>/dev/null \
        || true
}

# block until ready-file appears or 30s timeout
_macos_wait_enforcer_ready() {
    _ready="/tmp/ai-sandbox-enforcer.ready"
    _elapsed=0
    print_info "Waiting for VPN enforcer to apply network state..."
    _timeout=300
    while [ "$_elapsed" -lt "$_timeout" ]; do
        if [ -f "$_ready" ]; then
            print_info "VPN enforcer ready (${_elapsed}s)."
            return "$SUCCESS"
        fi
        sleep 1
        _elapsed=$(( _elapsed + 1 ))
        printf '  [%2ds / %ds]\r' "$_elapsed" "$_timeout" >&2
    done
    printf '\n' >&2
    print_error \
        "VPN enforcer did not become ready within ${_timeout}s."
    print_error \
        "Check logs: ~/Library/Logs/ai-agents-sandbox/macos-vpn-enforcer.log"
    return "$FAILURE"
}

# Set up VPN enforcement before container start (macOS run hook).
# Sets $_iface to empty (nftables enforcement replaces outbound_addr).
# Returns FAILURE if enforcement cannot be established.
_macos_run_setup() {
    if ! _macos_ensure_enforcer; then
        return "$FAILURE"
    fi
    if ! _handle_macos_vpn_state; then
        return "$FAILURE"
    fi
    if ! _macos_start_enforcer; then
        print_error "Failed to start VPN enforcer."
        rm -f "$_ENFORCER_CONF"
        return "$FAILURE"
    fi
    if ! _macos_wait_enforcer_ready; then
        _macos_stop_enforcer
        rm -f "$_ENFORCER_CONF"
        return "$FAILURE"
    fi
    return "$SUCCESS"
}

# Tear down VPN enforcement after container exits (macOS run hook).
_macos_run_teardown() {
    _macos_stop_enforcer
    rm -f "$_ENFORCER_CONF"
}

# Disable microVM on macOS: KVM is not available; Podman Machine provides
# VM isolation via Apple Hypervisor.framework. Sets USE_MICROVM=0.
_macos_adjust_microvm() {
    if [ "$USE_MICROVM" = "1" ]; then
        print_warning "[!] macOS detected — KVM is not available;"
        print_warning "    -> running without microVM isolation"
        print_warning \
            "    -> Podman Machine already provides a VM boundary via Apple"
        print_warning "       Hypervisor.framework"
        USE_MICROVM=0
    fi
}
