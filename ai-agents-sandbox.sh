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

# Main variables
PRJ_ID="ai-agents-sandbox"

# Path variables
ROOT_D="$(cd "$(dirname "$0")" && pwd)"
IMG_D="${ROOT_D}/image"
SANDBOX_D_DEFAULT="$ROOT_D/workspace"
SANDBOX_D="${SANDBOX_D_DEFAULT}"
CONF_P="${ROOT_D}/${PRJ_ID}.conf"
CACHE_D_DEFAULT="${HOME}/.cache/${PRJ_ID}"
CACHE_D="${CACHE_D_DEFAULT}"
BUILD_HOOK_ARG=""
BUILD_HOOK=""
BUILD_HOOK_P="${IMG_D}/hooks/build"
RUN_HOOK_ARG=""
RUN_HOOK=""
RUN_HOOK_P="${IMG_D}/hooks/run"

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
PKGS=""

# argument variables
AGENT=""
USE_MICROVM=1
ACTION=""
ALL=false
TOOLS_NEEDED="podman sed grep"

# useful vars
MIN_LIBKRUN_VER="1.18.0"

# ========
# Includes
# --------

. "${ROOT_D}/printer.sh"

# Source macOS-specific helpers (VPN enforcement, enforcer lifecycle).
# Provides: _macos_run_setup, _macos_run_teardown, _macos_remove_enforcer,
#           plus _ENFORCER_CONF and all _macos_* internals.
if [ "$(uname -s)" = "Darwin" ]; then
    . "${ROOT_D}/scripts/macos-sandbox.sh"
fi

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

# parse configuration file if it exists
_parse_conf() {
    if [ -f "$CONF_P" ]; then
        _in_block=0
        _block_key=""
        while IFS= read -r _line; do
            # strip leading whitespace
            _line="${_line#"${_line%%[! ]*}"}"
            case "$_line" in
                "" | \#*) continue ;;
            esac
            if [ "$_in_block" -eq 1 ]; then
                case "$_line" in
                    *")"*) _in_block=0; _block_key="" ;;
                    *)
                        # strip quotes
                        _item=$(printf '%s' "$_line" \
                            | sed 's/^["'"'"']//;s/["'"'"']$//')
                        # Assigning to block keys
                        case "$_block_key" in
                            PACKAGES) PKGS="$PKGS $_item" ;;
                        esac
                        ;;
                esac
            else
                _key="$(printf '%s' "$_line" | cut -d '=' -f 1)"
                _value="$(printf '%s' "$_line" | cut -d '=' -f 2-)"
                # strip quotes
                _value=$(printf '%s' "$_value" \
                    | sed 's/^["'"'"']//;s/["'"'"']$//')
                case "$_value" in
                    *"("*) _in_block=1; _block_key="$_key" ;;
                    *)
                        # Assigning to keys
                        case "$_key" in
                            AGENT) AGENT="$_value" ;;
                            USE_MICROVM) USE_MICROVM="$_value" ;;
                            WORKSPACE) SANDBOX_D="$_value" ;;
                            CACHE) CACHE_D="$_value" ;;
                            IMG_TAG) IMG_TAG="$_value" ;;
                        esac
                esac
            fi
        done < "$CONF_P"
    fi
    return "$SUCCESS"
}

# Get hooks according type of the argument, directory or single file.
# Id directory, it will return all scripts matching '[0-9][0-9]-*.sh'
_parse_hooks_f() {
    _hooks=""
    if [ -d "$1" ]; then
        for _h in "$1"/*.sh; do
            _h=$(echo "$_h" | sed -e 's|//|/|') # remove double slashes
            case "$(basename "$_h")" in
                [0-9][0-9]-*.sh) {
                    if [ -z "$_hooks" ]; then
                        _hooks="$_h"
                    else
                        _hooks="$_hooks $_h"
                    fi
                };;
            esac
        done
    elif [ -f "$1" ]; then
        _hooks="$1"
    fi
    echo "$_hooks"
}

# check if scripts exist and are valid (shellcheck if available).
_check_scripts() {
    _ret="$SUCCESS"
    _script="$1"
    if [ -n "$_script" ] && [ -f "$_script" ]; then
        if command -v shellcheck > /dev/null 2>&1; then
            if ! shellcheck "$_script" > /dev/null 2>&1; then
                print_error \
                    "Script '$_script' has shellcheck errors."
                _ret="$FAILURE"
            fi
        fi
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

# check if agent is valid
_valid_agent() {
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

# check if a local image exists
_image_exists() {
    _img="$1"
    podman image exists "$_img"
}

# Verify that the directory exists and is a directorynot set to HOME
_verify_mount_point() {
    _ret="$FAILURE"
    if [ -z "$1" ]; then
        print_warning "Workspace directory is not set."
    elif [ ! -e "$1" ] || [ ! -d "$1" ]; then
        print_warning "Workspace directory '$1' not found or not a directory."
    elif [ "$1" = "${HOME}" ]; then
        print_warning "Directory is set to the home directory, not recommended."
    else
        _ret="$SUCCESS"
    fi
    return "$_ret"
}
_verify_workspace_d() {
    _ret="$SUCCESS"
    SANDBOX_D="$(echo "${SANDBOX_D}" | sed "s|~|${HOME}|g")"
    _verify_mount_point "$SANDBOX_D" || {
        # Default could be overriding.
        if [ "$SANDBOX_D_DEFAULT" = "$HOME" ]; then
            print_error "Default sandbox workspace points to HOME. Consider the"
            print_error "use of '--workspace' to choose the workspace volume to"
            print_error "mount."
            _ret="$FAILURE"
        else
            print_warning "Falling back to default workspace: '$SANDBOX_D_DEFAULT'."
            SANDBOX_D="$SANDBOX_D_DEFAULT"
        fi
    }
    return "$_ret"
}
_verify_cache_d() {
    CACHE_D="$(echo "${CACHE_D}" | sed "s|~|${HOME}|g")"
    _verify_mount_point "$CACHE_D" || {
        print_warning "Falling back to default cache: '$CACHE_D_DEFAULT'."
        CACHE_D="$CACHE_D_DEFAULT"
    }
}

# Bind auth mounts for the agent, if applicable
_bind_auth_mounts() {
    _auth="${CACHE_D}/.auth"
    _home="/home/aiuser"
    _mounts=""
    _gemini_mounted=0
    _gcloud_mounted=0

    case " $AGENT " in *" copilot "*)
        mkdir -p "${_auth}/.config/gh" "${_auth}/.copilot"
        _mounts="$_mounts --volume $_auth/.config/gh:$_home/.config/gh:z"
        _mounts="$_mounts --volume $_auth/.copilot:$_home/.copilot:z"
    ;; esac
    
    # gemini + antigravity share ~/.gemini/
    case " $AGENT " in *" gemini "*|*" antigravity "*)
        if [ "$_gemini_mounted" = "0" ]; then
            mkdir -p "$_auth/.gemini"
            _mounts="$_mounts --volume $_auth/.gemini:$_home/.gemini:z"
            _gemini_mounted=1
        fi
    ;; esac

    # claude
    case " $AGENT " in *" claude "*)
        mkdir -p "$_auth/.claude"
        touch "$_auth/.claude.json"          # must exist as file before mount
        _mounts="$_mounts --volume $_auth/.claude:$_home/.claude:z"
        _mounts="$_mounts --volume $_auth/.claude.json:$_home/.claude.json:z"
    ;; esac

    # claude (Vertex) + opencode share ~/.config/gcloud/
    case " $AGENT " in *" claude "*|*" opencode "*)
        if [ "$_gcloud_mounted" = "0" ]; then
            mkdir -p "$_auth/.config/gcloud"
            _mounts="$_mounts \
--volume $_auth/.config/gcloud:$_home/.config/gcloud:z"
            _gcloud_mounted=1
        fi
    ;; esac

    # opencode
    case " $AGENT " in *" opencode "*)
        mkdir -p "$_auth/.config/opencode"
        _mounts="$_mounts \
--volume $_auth/.config/opencode:$_home/.config/opencode:z"
    ;; esac

    # hermes-agent
    case " $AGENT " in *" hermes-agent "*)
        mkdir -p "$_auth/.hermes"
        _mounts="$_mounts --volume $_auth/.hermes:$_home/.hermes:z"
    ;; esac

    printf '%s' "$_mounts"
}

# ================
# Action functions
# ----------------

# Print usage information
usage() {
    _str="Usage: ${PRJ_ID} [-q|-v|-h] <actions> <agent> [options]
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
  (trusted)     ${TRUSTED_AGENTS}
  (untrusted)   ${UNTRUSTED_AGENTS}
                if no agent is specified, all trusted agents will be built
                (only for build action)

Options:
  --no-microvm Run the sandbox without microVM isolation (not recommended)
  --cache      Defined path for caching agent's data
  --conf       Defined conf file path for building the image. See Notes.
  --build-hook Defined hook(s) path for building the image. See Notes.
  --run-hook   Defined hook(s) path for running the image. See Notes.
  --workspace, -w <dir>
               For 'run' action, Specify a custom workspace directory
               (default: ${SANDBOX_D_DEFAULT}) to mount in the sandbox at
               /home/aiuser/workspace.
  --all, -a    For 'clean' action, also remove home volume and auth tokens

Notes:
  - The sandbox is designed to run in a secure, isolated environment.
  - Untrusted agents may not comply with best practices and could pose security
    risks.
  - To enable microVM isolation, ensure that KVM is available and the user is in
    the kvm group.
  - To configure the sandbox, you can 
    1. create a configuration file at ${CONF_P} with the following format:
    AGENT=<agent_name>
    USE_MICROVM=1
    WORKSPACE=<workspace_directory>
    IMG_TAG=<image_tag>
    PACKAGES=(
        <package1>
        <package2>
        ...
    )
    2. Create hooks to customize the image build. Gives the path to a script or
       to a folder containing '[0-9][0-9]-xxx.sh' scripts. Will be run as root.
    3. Create hooks to customize the container. Gives the path to a script or
       to a folder containing '[0-9][0-9]-xxx.sh' scripts. Will be run as
       userai.
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

    # TODO: Get the hooks from vendordir `/usr/etc/${PRJ_ID}/*`
    # TODO: Get the hooks from admin config `/etc/${PRJ_ID}/*`
    [ -n "${BUILD_HOOK_ARG}" ] && BUILD_HOOK="$(_parse_hooks_f "${BUILD_HOOK_ARG}")"
    [ -n "${RUN_HOOK_ARG}" ] && RUN_HOOK="$(_parse_hooks_f "${RUN_HOOK_ARG}")"
    for _h in "$BUILD_HOOK" "$RUN_HOOK"; do
        if ! _check_scripts "$_h"; then
            return "$FAILURE"
        fi
    done

    # When IMG_D is not writable (e.g. system-wide install), stage
    # hooks in a temp copy of the build context so podman can COPY
    # them without needing write access to the installed share dir.
    _img_ctx="${IMG_D}"
    if [ -n "$BUILD_HOOK" ] || [ -n "$RUN_HOOK" ]; then
        if [ ! -w "${IMG_D}/hooks" ]; then
            _img_ctx="$(mktemp -d)"
            cp -r "${IMG_D}/." "${_img_ctx}/"
            BUILD_HOOK_P="${_img_ctx}/hooks/build"
            RUN_HOOK_P="${_img_ctx}/hooks/run"
        fi
    fi

    # Copy user hooks into the build context so podman can COPY
    # them without escaping the context directory.
    [ -n "$BUILD_HOOK" ] && {
        print_debug "Copying build hook(s) to build context: ${BUILD_HOOK_P}"
        print_debug "  -> Source: $BUILD_HOOK"
        for _h in $BUILD_HOOK; do
            cp "$_h" "${BUILD_HOOK_P}/"
        done
    }
    [ -n "$RUN_HOOK" ] && {
        print_debug "Copying run hook(s) to build context: ${RUN_HOOK_P}"
        print_debug "  -> Source: $RUN_HOOK"
        for _h in $RUN_HOOK; do
            cp "$_h" "${RUN_HOOK_P}/"
        done
    }

    print_info "Building container image ${IMG_NAME}:${IMG_TAG} ..."
    if ! podman build \
        --no-cache \
        --rm \
        --build-arg "AGENT=${AGENT}" \
        --build-arg "IMG_TAG=${IMG_TAG}" \
        --build-arg "PKGS=${PKGS}" \
        --tag "${IMG_NAME}:${IMG_TAG}" \
        --tag "${IMG_NAME}:latest" \
        --file "${_img_ctx}/Containerfile" \
        "${_img_ctx}"; then
            print_error "Image build failed."
            _ret="$FAILURE"
    else
        print_info "Image built successfully."
    fi

    # clean up temporary hook files from build context
    for _hook in $BUILD_HOOK $RUN_HOOK; do
        _hook_n="$(basename "$_hook")"
        _hook_p="${BUILD_HOOK_P}/${_hook_n}"
        if [ -z "$_hook_p" ] || [ ! -f "$_hook_p" ]; then
            _hook_p="${RUN_HOOK_P}/${_hook_n}"
            if [ -z "$_hook_p" ] || [ ! -f "$_hook_p" ]; then
                print_warning "Hook '$_hook_n' not found in build or run hooks."
                continue
            fi
        fi
        print_debug "Removing temporary hook file: $_hook_p"
        rm -f "$_hook_p"
    done
    # Remove temp build context if it was created
    [ "${_img_ctx}" != "${IMG_D}" ] && rm -rf "${_img_ctx}"
    return "$_ret"
}

# callback for run action
run() {
    _ret="$SUCCESS"

    _verify_workspace_d || return "$FAILURE"
    
    [ "$(uname -s)" = "Darwin" ] && _macos_adjust_microvm
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
    
    if [ "$USE_MICROVM" = "1" ]; then
        TOOLS_NEEDED="$TOOLS_NEEDED krun"
        CTN_NAME="${CTN_NAME}-microvm"
    else
        TOOLS_NEEDED="$TOOLS_NEEDED passt"
        if [ "$(uname -s)" != "Darwin" ]; then
            TOOLS_NEEDED="$TOOLS_NEEDED ip"
        fi
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

    if [ "$(uname -s)" = "Darwin" ]; then
        if ! _macos_run_setup; then
            return "$FAILURE"
        fi
    else
        _iface="$(_detect_public_iface)" || true
        if [ -z "$_iface" ]; then
            print_error \
                "Could not detect a non-VPN interface."
            print_error \
                "Aborting to avoid unrestricted egress."
            return "$FAILURE"
        fi
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
                    if ! podman exec -it "$CTN_NAME" bash; then
                        _ret="$FAILURE"
                    fi
                    [ "$(uname -s)" = "Darwin" ] && _macos_run_teardown
                    return "$_ret"
                fi
            };;
            initialized|created|configured|exited) {
                print_info "Starting container from '$STATE'..."
                if ! podman start -ai "$CTN_NAME"; then
                    _ret="$FAILURE"
                fi
                [ "$(uname -s)" = "Darwin" ] && _macos_run_teardown
                return "$_ret"
            };;
            *)       {
                print_error "Container '$CTN_NAME' is in state '$STATE'"
                print_error "  -> Cannot attach or resume."
                print_error "  -> Please use 'clean' before 'run'."
                return "$FAILURE"
            };;
        esac
    fi

    _auth_mounts="$(_bind_auth_mounts)"
    set --
    [ "$USE_MICROVM" = "1" ] && set -- --runtime krun
    set -- "$@" \
        --name "$CTN_NAME" \
        "${_auth_mounts}" \
        --volume "$SANDBOX_D:/home/aiuser/workspace:z" \
        --tmpfs "/tmp:rw,nosuid,noexec,size=1g" \
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
    
    # On macOS, pasta:outbound_addr cannot bind at the host
    # level because containers run inside Podman Machine (Linux
    # VM) and all traffic is proxied through gvproxy on the macOS
    # host. VM-layer nftables enforcement is handled by
    # macos-vpn-enforcer.sh (started above via launchctl).
    # On Linux, outbound_addr pins egress to the detected
    # non-VPN interface at the kernel level.
    if [ "$(uname -s)" = "Darwin" ]; then
        # On macOS, containers run inside the Podman Machine VM.
        # gvproxy provides DNS via its internal resolver (VM gateway),
        # which forwards to mDNSResponder — VPN-aware and not subject
        # to the nftables oif rules. Overriding with 1.1.1.1/8.8.8.8
        # breaks sites like googleapis.com when the corporate VPN
        # intercepts or blocks direct UDP/53 to external resolvers.
        print_info "VM-layer nftables enforcement active."
        set -- "$@" --network pasta
    else
        print_info "Binding outbound to interface: $_iface"
        set -- "$@" --network "pasta:--outbound-if4,${_iface}" \
            --dns 1.1.1.1 --dns 8.8.8.8
    fi

    if [ "$USE_MICROVM" = "1" ]; then
        # Available on crun > 1.27, below /.krun_config.json in the image is
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
    [ "$(uname -s)" = "Darwin" ] && _macos_run_teardown
    return "$_ret"
}

# callback for clean action
clean() {
    _ret="$SUCCESS"
    if [ "$(uname -s)" != "Darwin" ] && [ "$USE_MICROVM" = 1 ]; then
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
        # Keep care of old volumes
        # ---
        _home_volume="$CTN_NAME-home"
        if podman volume exists "$_home_volume"; then
            if ! podman volume rm -f "$_home_volume"; then
                print_error "Failed to remove volume '$_home_volume'."
                _ret="$FAILURE"
            fi
        fi
        # ---
        _auth_dir="$CACHE_D/.auth"
        if [ -d "$_auth_dir" ]; then
            print_info "Removing auth directory '$_auth_dir'..."
            rm -rf "$_auth_dir"
            print_info "Auth tokens cleaned."
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
        help|--help|-h)          usage;               exit 0  ;;
        verbose|--verbose|-v)    VERBOSE=1;           shift 1 ;;
        quiet|--quiet|-q)        QUIET=1;             shift 1 ;;
        version|--version)       print_version;       exit 0  ;;
        run|build|clean|status)  ACTION="$1";         shift 1 ;;
        --no-microvm|no-microvm) USE_MICROVM=0;       shift 1 ;;
        --conf)                  CONF_P="$2";         shift 2 ;;
        --cache)                 CACHE_D="$2";        shift 2 ;;
        --build-hook)            BUILD_HOOK_ARG="$2"; shift 2 ;;
        --run-hook)              RUN_HOOK_ARG="$2";   shift 2 ;;
        all|--all|-a)            ALL=true;            shift 1 ;;
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

if ! _parse_conf; then
    print_error "Failed to parse configuration file: $CONF_P"
    exit $FAILURE
fi

[ "$CACHE_D" != "${CACHE_D_DEFAULT}" ] && _verify_cache_d

if [ "$AGENT" != "" ]; then
    if ! _valid_agent ; then
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
