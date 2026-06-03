#!/bin/sh
# AI Agents Sandbox - Manage a secure, isolated environment for running agents.
# Copyright (C) 2026  val4oss <val4oss@pm.me>
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANYWARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# ================
# Global variables
# ----------------

# Return codes
SUCCESS=0
FAILURE=1

# Path variables
ROOT_D="$(cd "$(dirname "$0")" && pwd)"
IMG_D="${ROOT_D}/image"
SANDBOX_D_DEFAULT="$ROOT_D/workspace"
SANDBOX_D="${SANDBOX_D_DEFAULT}"

# Container variables
IMG_NAME="ai-agents-sandbox"
CTN_NAME="ai-agents-sandbox"
IMG_TAG="0.9.0"
TRUSTED_AGENTS="copilot claude gemini opencode antigravity"
UNTRUSTED_AGENTS="hermes-agent"
UNTRUSTED_AGENTS_SENSITIVE_ACTIONS="build run"
AI_USER_NAME="aiuser"
AI_USER_UID=1000
AI_USER_GID=1000

# argument variables
AGENT=""
USE_MICROVM=1
ACTION=""
ALL=false
TOOLS_NEEDED="podman sed grep"

# usefull var
MIN_LIBKRUN_VER="1.18.0"

# ========
# Includes
# --------

. "${ROOT_D}/printer.sh"

# ==================
# Internal functions
# ------------------

# check if needed tools are available on the system
_check_tools_needed() {
    _ret="$SUCCESS"
    for dep in $TOOLS_NEEDED; do
        if ! command -v "$dep" > /dev/null 2>&1; then
            if [ ${missing_deps+x} ]; then
                missing_deps="$missing_deps $dep"
            else
                missing_deps="$dep"
            fi
        fi
    done
    if [ ${missing_deps+x} ]; then
        print_error "Some tools are missing on your system: $missing_deps"
        _ret="$FAILURE"
    fi
    return "$_ret"
}

# print warning and prompt confirmation for untrusted agent
_check_untrusted_disclaimer() {
    print_warning "WARNING: The agent '$1' is considered UNTRUSTED"
    print_warning \
        "and does not comply with SUSE internal best practices."
    printf "Do you want to continue? [y/N]: "
    read -r _ans
    case "$_ans" in
        [Yy]* ) ;;
        * ) exit "$FAILURE";;
    esac
}

# check if agent is valide
_valide_agent() {
    _ret="$FAILURE"
    for _agt_v in $TRUSTED_AGENTS; do
        if [ "$AGENT" = "$_agt_v" ]; then
            _ret="$SUCCESS"
            return "$_ret"
        fi
    done
    for _agt_v in $UNTRUSTED_AGENTS; do
        if [ "$AGENT" = "$_agt_v" ]; then
            for _act_v in $UNTRUSTED_AGENTS_SENSITIVE_ACTIONS; do
                if [ "$ACTION" = "$_act_v" ]; then
                    _check_untrusted_disclaimer "$AGENT"
                    break
                fi
            done
            _ret="$SUCCESS"
            return "$_ret"
        fi
    done
    return "$_ret"
}

_check_microvm() {
    _ret="$SUCCESS"
    if [ ! -x "/usr/bin/krun" ]; then
        print_warning "krun not found at /usr/bin/krun."
        print_warning "     -> Install it via your package manager."
        _ret="$FAILURE"
    fi

    # for microvm libkrun needs to be > 1.18.0, that includes this fix:
    # https://github.com/containers/libkrun/commit/757b080b4c5f5934f8e5320a38b401aaec116764
    _libname="$(readlink "$(find /usr/lib*/ -name "libkrun.so.1" 2>/dev/null)")"
    if [ -n "$_libname" ]; then
        _ver="$(printf "%s" "$_libname" | sed -E 's/.*\.so\.//')"
        print_debug "Found libkrun version: $_ver"
        if [ -n "$_ver" ] &&\
            printf '%s\n' "$_ver" |\
            awk -F . '{ printf("%d%03d%03d\n", $1,$2,$3); }' |\
            awk -v req="$(printf '%s\n' "${MIN_LIBKRUN_VER}" |\
            awk -F . '{ printf("%d%03d%03d\n", $1,$2,$3); }')" \
                '{ if ($1 < req) exit 0; else exit 1; }'; then
            print_warning "libkrun version is too old (found: $_ver, required: > ${MIN_LIBKRUN_VER})."
            print_warning "     -> Please update libkrun to a version > ${MIN_LIBKRUN_VER}."
            _ret="$FAILURE"
        fi
    else
        print_debug "libkrun version not found"
    fi

    if [ ! -c /dev/kvm ]; then
        print_warning "/dev/kvm not found — KVM is not available on this host."
        print_warning "     -> Enable it by loading the kvm_amd or kvm_intel"
        print_warning "        kernel module."
        _ret="$FAILURE"
    fi

    if ! id -Gn | tr ' ' '\n' | grep -qx kvm; then
        print_warning "User \"$(id -un)\" is not in the kvm group."
        print_warning "     -> Run 'sudo usermod -aG kvm $(id -un)'"
        print_warning "        (then relogin)."
        _ret="$FAILURE"
    fi

    # Nested-virtualisation check — warn only, does not abort
    if [ -f /sys/module/kvm_intel/parameters/nested ]; then
        if [ "$(cat /sys/module/kvm_intel/parameters/nested)" != "Y" ]; then
            print_warning "Nested virtualization is not enabled on this host."
            print_warning "This may cause issues when running microVMs inside \
another VM."
        fi
    elif [ -f /sys/module/kvm_amd/parameters/nested ]; then
        if [ "$(cat /sys/module/kvm_amd/parameters/nested)" != "1" ]; then
            print_warning "Nested virtualization is not enabled on this host."
            print_warning "This may cause issues when running microVMs inside \
another VM."
        fi
    fi

    return "$_ret"
}

# Detect the default public-facing interface, excluding VPN/tunnel interfaces.
# Returns the first default-route interface not matching tun|wg|vpn|tap|ppp.
_detect_public_iface() {
    _ret="$SUCCESS"
    _iface=""

    if command -v ip > /dev/null 2>&1; then
        _iface="$(ip route show default \
            | awk '{print $5}' \
            | grep -Ev 'tun|wg|vpn|tap|ppp' \
            | head -1)"
    elif command -v route > /dev/null 2>&1; then
        _iface="$(route -n get default 2>/dev/null \
            | awk '/interface:/{print $2; exit}' \
            | grep -Ev 'tun|wg|vpn|tap|ppp' \
            | head -1)"
    fi

    if [ -n "$_iface" ]; then
        printf "%s\n" "$_iface"
    else
        _ret="$FAILURE"
    fi

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

    launchctl stop "com.ai-agents-sandbox.macos-vpn-enforcer" 2>/dev/null || true
    launchctl unload "$_plist_dst" 2>/dev/null || true

    cp "$_plist_tmpl" "$_plist_dst"
    if ! _sed_inplace "s|{{SCRIPT_PATH}}|${_script_dst}|g" "$_plist_dst"; then
        print_error "Failed to update plist SCRIPT_PATH."
        return "$FAILURE"
    fi
    if ! _sed_inplace "s|{{LOG_DIR}}|${_log_dir}|g" "$_plist_dst"; then
        print_error "Failed to update plist LOG_DIR."
        return "$FAILURE"
    fi

    # Inject runtime PATH so launchd can find podman.
    # launchd does not inherit the user's shell PATH.
    _podman_bin="$(command -v podman 2>/dev/null)"
    _podman_dir="$(dirname "$_podman_bin" 2>/dev/null)"
    _plist_path="${_podman_dir}:/opt/homebrew/bin"
    _plist_path="${_plist_path}:/usr/local/bin"
    _plist_path="${_plist_path}:/usr/bin:/bin:/usr/sbin:/sbin"
    if ! _sed_inplace "s|{{HOME}}|${HOME}|g" "$_plist_dst"; then
        print_error "Failed to update plist HOME."
        return "$FAILURE"
    fi
    if ! _sed_inplace "s|{{PATH}}|${_plist_path}|g" "$_plist_dst"; then
        print_error "Failed to update plist PATH."
        return "$FAILURE"
    fi

    _launch_domain="gui/$(id -u)"
    if ! launchctl bootstrap "$_launch_domain" "$_plist_dst" 2>/dev/null; then
        # Fallback for older launchctl variants.
        if ! launchctl load "$_plist_dst" 2>/dev/null; then
            print_error "Failed to load VPN enforcer LaunchAgent."
            return "$FAILURE"
        fi
    fi

    if ! launchctl print "${_launch_domain}/com.ai-agents-sandbox.macos-vpn-enforcer" \
        >/dev/null 2>&1; then
        print_error "VPN enforcer LaunchAgent is not loaded."
        return "$FAILURE"
    fi

    print_info "VPN enforcer LaunchAgent ready."
    return "$SUCCESS"
}

# remove the macOS VPN enforcer LaunchAgent and nftables rules
_macos_remove_enforcer() {
    _plist_dst="$HOME/Library/LaunchAgents/com.ai-agents-sandbox.macos-vpn-enforcer.plist"
    _log_dir="$HOME/Library/Logs/ai-agents-sandbox"
    _script_dst="$HOME/.local/bin/ai-sandbox-macos-vpn-enforcer"
    _label="com.ai-agents-sandbox.macos-vpn-enforcer"
    _service="gui/$(id -u)/${_label}"

    launchctl stop "$_label" 2>/dev/null || true
    launchctl bootout "$_service" 2>/dev/null || true
    launchctl unload "$_plist_dst" 2>/dev/null || true

    if podman machine ssh -- true 2>/dev/null; then
        podman machine ssh -- sudo nft delete table inet vpn-block 2>/dev/null || true
    fi

    rm -f "$_plist_dst" "$_script_dst" \
        "$HOME/.local/bin/macos-network-policy.sh" \
        "$_log_dir/macos-vpn-enforcer.log" \
        "$_log_dir/macos-vpn-enforcer.err" \
        "$_log_dir/vpn-enforcer.log" \
        "$_log_dir/vpn-enforcer.err" \
        "$_ENFORCER_CONF" \
        "/tmp/ai-sandbox-enforcer.ready" \
        "/tmp/ai-sandbox-enforcer.state"

    # Remove the directory only if it is empty after log cleanup.
    rmdir "$_log_dir" 2>/dev/null || true

    print_info "VPN enforcer removed."
    return "$SUCCESS"
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
        print_error "VPN enforcer LaunchAgent is not loaded: $_service"
        print_error "Run action will not continue without VPN enforcement."
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
    launchctl stop "com.ai-agents-sandbox.macos-vpn-enforcer" 2>/dev/null || true
}

# block until ready-file appears or 30s timeout
_macos_wait_enforcer_ready() {
    _ready="/tmp/ai-sandbox-enforcer.ready"
    _elapsed=0
    print_info "Waiting for VPN enforcer to apply network state..."
    timeout=300
    while [ "$_elapsed" -lt "$timeout" ]; do
        if [ -f "$_ready" ]; then
            print_info "VPN enforcer ready (${_elapsed}s)."
            return "$SUCCESS"
        fi
        sleep 1
        _elapsed=$(( _elapsed + 1 ))
        printf '  [%2ds / %ds]\r' "$_elapsed" "$timeout" >&2
    done
    printf '\n' >&2
    print_error "VPN enforcer did not become ready within ${timeout}s."
    print_error "Check logs: ~/Library/Logs/ai-agents-sandbox/macos-vpn-enforcer.log"
    return "$FAILURE"
}

# check if a local image exists
_image_exists() {
    _img="$1"
    podman image exists "$_img"
}

# Verify that the workspace directory exists and is a directory, otherwise fall
# back to the default workspace directory. Also warn if the workspace is set to
# the home directory.
_verify_workspace() {
    SANDBOX_D="$(echo "${SANDBOX_D}" | sed "s|~|${HOME}|g")"
    if [ ! -e "$SANDBOX_D" ] || [ ! -d "$SANDBOX_D" ]; then
        print_warning "Workspace directory '$SANDBOX_D' does not exist or is not a directory."
        print_warning "Falling back to default workspace directory: '$SANDBOX_D_DEFAULT'."
        SANDBOX_D="$SANDBOX_D_DEFAULT"
    elif [ "$SANDBOX_D" = "${HOME}" ]; then
        print_warning "Workspace directory is set to the home directory, which is not recommended."
        print_warning "Falling back to default workspace directory: '$SANDBOX_D_DEFAULT'."
        SANDBOX_D="$SANDBOX_D_DEFAULT"
    fi
}

# ================
# Action functions
# ----------------

# Print usage information
usage() {
    _str="Usage: $0 [-q|-v|-h] <actions> <agent> [options]
  -q, --quiet   Suppress all output except errors
  -v, --verbose Enable verbose output
  --version     Show version information and exit
  -h, --help    Show this help message and exit

Actions:
  run           Run the sandbox with the specified agent
  build         Build the container image for the specified agent
  clean         Remove built images and containers for the specified agent
  status        Show the current status, built images, running containers...

Agents:
  (trusted)     $TRUSTED_AGENTS
  (untrusted)   $UNTRUSTED_AGENTS
                if no agent is specified, all agents will be built
                (only for build action)

Options:
  no-microvm    Run the sandbox without microVM isolation (not recommended)
  --wokspace, -w <dir>
                For 'run' action, Specify a custom workspace directory
                (default: $SANDBOX_D_DEFAULT) to mount in the sandbox at
                /home/aiuser/workspace.

  --all, -a     For 'clean' action, also remove home volume and auth tokens
"
    printf "%s\n" "$_str"
}

# Print version information
print_version() {
    printf "AI Agents Sandbox version: %s\n" "$IMG_TAG"
}

# callback for build action
build() {
    _ret="$SUCCESS"
    print_info "Building container image ${IMG_NAME}:${IMG_TAG} ..."
    if ! podman build \
        --build-arg "AGENT=${AGENT}" \
        --build-arg "IMG_TAG=${IMG_TAG}" \
        --tag "${IMG_NAME}:${IMG_TAG}" \
        --tag "${IMG_NAME}:latest" \
        --file "${IMG_D}/Containerfile" \
        "${IMG_D}"; then
            print_error "Image build failed."
            _ret="$FAILURE"
    else
        print_info "Image built successfully."
    fi
    return "$_ret"
}

# callback for run action
run() {
    _ret="$SUCCESS"
    
    if [ "$(uname -s)" = "Darwin" ] && [ "$USE_MICROVM" = "1" ]; then
        print_warning "[!] macOS detected — KVM is not available;"
        print_warning "    -> running without microVM isolation"
        print_warning "    -> Podman Machine already provides a VM boundary via\
 Apple"
        print_warning "       Hypervisor.framework"
        USE_MICROVM=0
    fi

    if [ "$USE_MICROVM" -eq 1 ]; then
        if [ "$AGENT" = "copilot" ] || [ "$AGENT" = "opencode" ]; then
            print_warning "${AGENT} CLI sends large HTTP/2 frames that trigger a krun vsock"
            print_warning "BufDescTooSmall bug. Falling back to no-microvm for ${AGENT}."
            print_warning "Tracking: https://github.com/containers/libkrun/issues/674"
            USE_MICROVM=0
        elif ! _check_microvm; then
            print_warning "MicroVM isolation is not available."
            print_warning "     -> Running without it for agent '${AGENT}' \
(not recommended)..."
            USE_MICROVM=0
        else
            print_info "Running sandbox with microVM isolation for agent \
'${AGENT}'..."
        fi
    else
        print_warning "Running sandbox without microVM isolation for agent \
'${AGENT}' (not recommended)..."
    fi
    
    _home_volume="$CTN_NAME-home"
    if podman volume exists "$_home_volume"; then
        print_debug "Using existing home volume '$_home_volume'."
    else
        print_info "Creating home volume '$_home_volume'..."
        if ! podman volume create "$_home_volume" ; then
            print_error "Failed to create volume '$_home_volume'."
            return "$FAILURE"
        fi
    fi

    if [ "$USE_MICROVM" = "1" ]; then
        TOOLS_NEEDED="$TOOLS_NEEDED krun"
        CTN_NAME="${CTN_NAME}-microvm"
    else
        TOOLS_NEEDED="$TOOLS_NEEDED slirp4netns ip"
    fi

    if [ -n "$GOOGLE_CLOUD_PROJECT$VERTEX_LOCATION" ] && \
        podman container exists "$CTN_NAME"; then
        print_warning "Vertex env vars are applied only when creating a new container."
        print_warning "     -> Use 'clean ${AGENT}' then 'run ${AGENT}' to apply updates."
    fi

    if ! _check_tools_needed; then
        print_error "Required tools for the selected isolation are missing."
        print_error "Please install them and try again."
        return "$FAILURE"
    fi

    # Resume a stopped container
    if podman container exists "$CTN_NAME"; then
        STATE=$(podman inspect "$CTN_NAME" --format '{{.State.Status}}')
        case "$STATE" in
            running) {
                _runtime=$(
                    podman inspect "$CTN_NAME" --format '{{.OCIRuntime}}'
                )
                if [ -n "$_runtime" ] && [ "$_runtime" = "krun" ]; then
                    _nbr="$(podman ps -a --format '{{.Names}}' |\
                            grep -c "$CTN_NAME")"
                    CTN_NAME="$CTN_NAME-$_nbr"
                    print_info "A container already run with '$_runtime'."
                    print_info "Creating a new one with suffixe $CTN_NAME."
                else
                    print_info "Attaching to running container..."
                    podman exec -it "$CTN_NAME" bash
                    return "$SUCCESS"
                fi
            };;
            exited)  {
                print_info "Resuming existing container..."
                podman start -ai "$CTN_NAME"
                return "$SUCCESS"
            };;
            *)       {
                print_error "Container '$CTN_NAME' is in state '$STATE'"
                print_error "  -> Cannot attach or resume."
                print_error "  -> Please use 'clean' before 'run'."
                return "$FAILURE"
            };;
        esac
    fi

    set --
    [ "$USE_MICROVM" = "1" ] && set -- --runtime krun
    set -- "$@" \
        --name "$CTN_NAME" \
        --volume "$_home_volume:/home/aiuser:z" \
        --volume "$SANDBOX_D:/home/aiuser/workspace:z" \
        --tmpfs "/tmp:rw,nosuid,size=1g" \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --userns="keep-id:uid=${AI_USER_UID},gid=${AI_USER_GID}" \
        --hostname ai-sandbox \
        --pids-limit 1024 \
        --env "AI_USER=${AI_USER_NAME}" \
        --env "AI_UID=${AI_USER_UID}" \
        --env "AI_GID=${AI_USER_GID}" \
        --env "AI_SANDBOX_VERSION=${IMG_TAG}"

    # Forward cloud/relay settings needed by Vertex-backed OpenCode sessions.
    if [ -n "$GOOGLE_CLOUD_PROJECT" ]; then
        set -- "$@" --env "GOOGLE_CLOUD_PROJECT=$GOOGLE_CLOUD_PROJECT"
    fi
    if [ -n "$VERTEX_LOCATION" ]; then
        set -- "$@" --env "VERTEX_LOCATION=$VERTEX_LOCATION"
    fi

    _iface=$(_detect_public_iface)
    if [ -n "$_iface" ]; then
        print_info "Binding outbound network to interface: $_iface"
        set -- "$@" --network "slirp4netns:outbound_addr=${_iface}"
        set -- "$@" --dns 1.1.1.1 --dns 8.8.8.8
    else
        print_warning "Could not detect a public interface;"
        print_warning "falling back to default slirp4netns."
        set -- "$@" --network slirp4netns
    fi
    if [ "$USE_MICROVM" = "1" ]; then
        # Avaialble on crun > 1.27, below /.krun_config.json in the image is
        # required
        set -- "$@" --annotation krun.ram_mib=8192 --annotation krun.cpus=4
    fi
    _args=$*
    print_info "Starting isolated container..."
    _cmd="podman run -it $_args ${IMG_NAME}:latest"
    print_debug "$_cmd"
    if ! eval "$_cmd"; then
        print_error "Failed to start container ${CTN_NAME}."
        _ret="$FAILURE"
    fi
    return "$_ret"
}

# callback for clean action
clean() {
    _ret="$SUCCESS"
    if [ "$USE_MICROVM" = "1" ]; then
        CTN_NAME="${CTN_NAME}-microvm"
    fi

    print_info "Cleaning containers for agent '${AGENT}'..."
    if podman container exists "$CTN_NAME"; then
        _ctns="$(podman ps -a --format '{{.Names}}' |\
            grep -E "$CTN_NAME-[0-9]+")"
        if [ -n "$_ctns" ]; then
            for _ctn in $_ctns; do
                print_info "Stopping and removing container '$_ctn'..."
                if podman rm -f "$_ctn"; then
                    print_info "Container removed."
                else
                    print_error "Failed to remove container '$_ctn'."
                    _ret="$FAILURE"
                fi
            done
        fi
        print_info "Stopping and removing container '$CTN_NAME'..."
        if podman rm -f "$CTN_NAME"; then
            print_info "Container removed."
        else
            print_error "Failed to remove container '$CTN_NAME'."
            _ret="$FAILURE"
        fi
    else
        print_info "No container '$CTN_NAME' found."
    fi

    if [ "$ALL" = true ]; then
        _home_volume="$CTN_NAME-home"
        if podman volume exists "$_home_volume"; then
            print_info "Removing home volume '$_home_volume'..."
            if podman volume rm -f "$_home_volume"; then
                print_info "Volume removed."
            else
                print_error "Failed to remove volume '$_home_volume'."
                _ret="$FAILURE"
            fi
        else
            print_debug "No volume '$_home_volume' found."
        fi

        if [ "$(uname -s)" = "Darwin" ]; then
            print_info "Removing macOS VPN enforcer artifacts..."
            if ! _macos_remove_enforcer; then
                print_error "Failed to remove VPN enforcer artifacts."
                _ret="$FAILURE"
            fi
        fi

        print_info "Auth tokens and workspace cleaned."
    fi
    return "$_ret"
}

# callback for status action
status() {
    printf "Images :\n"
    podman images \
        --sort created \
        --format "{{.Repository}}:{{.Tag}}" \
        --filter "reference=${IMG_NAME}*"\
        --filter "dangling=false" | while IFS= read -r line; do
        printf "  - %s\n" "$line"
    done
    printf "Containers :\n"
    podman ps -a \
        --format "{{.Names}} ({{.Image}}) [{{.Status}}]" \
        --filter "name=${CTN_NAME}*" | while IFS= read -r line; do
        printf "  - %s\n" "$line"
    done
    exit 0
}

# ===========
# Entry point
# -----------

_check_tools_needed || {
    print_error "Please install the missing tools and try again. Aborting."
    exit $FAILURE
}

# Get arguments
if [ $# -lt 1 ]; then
    print_error "Missing command"
    usage & exit 1
fi
while [ $# -gt 0 ]; do
    case "$1" in
        help|--help|-h)          usage;         exit 0  ;;
        verbose|--verbose|-v)    VERBOSE=1;     shift 1 ;;
        quiet|--quiet|-q)        QUIET=1;       shift 1 ;;
        version|--version)       print_version; exit 0  ;;
        run|build|clean|status)  ACTION="$1";   shift 1 ;;
        --no-microvm|no-microvm) USE_MICROVM=0; shift 1 ;;
        all|--all|-a)            ALL=true;      shift 1 ;;
        --workspace|-w)
            if [ -z "$2" ]; then
                print_error "Error: $1 requires an argument."
                exit 1
            fi
            SANDBOX_D="$2"
            shift 2
            ;;
        -*)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            AGENT="$1"
            shift 1
            ;;
    esac
done

_verify_workspace

if [ "$AGENT" != "" ]; then
    if ! _valide_agent ; then
        print_error "Unknown agent: '$AGENT'. \
Valid agents: $TRUSTED_AGENTS (trusted) or $UNTRUSTED_AGENTS (untrusted)"
        exit $FAILURE
    else
        IMG_NAME="${IMG_NAME}-${AGENT}"
        CTN_NAME="${CTN_NAME}-${AGENT}"
    fi
else
    AGENT="$TRUSTED_AGENTS"
fi

if ! eval "$ACTION"; then
    print_error "[✗] Action '$ACTION' failed."
    exit $FAILURE
else
    print_info "[✓] Done."
fi
