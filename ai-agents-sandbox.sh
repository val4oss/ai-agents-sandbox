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
RUN_HOOK_ARG=""

# Container variables
DEFAULT_IMG_REPO="registry.opensuse.org/home/vlefebvre/container-images/containers/opensuse"
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
DEBUG=0
BUILD_FULL=0
ALL=0
CLEAN_IMG=0
DNS_LIST=""
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
                            AGENT)       AGENT="$_value" ;;
                            USE_MICROVM) USE_MICROVM="$_value" ;;
                            WORKSPACE)   SANDBOX_D="$_value" ;;
                            CACHE)       CACHE_D="$_value" ;;
                            IMG_TAG)     IMG_TAG="$_value" ;;
                            DNS)         DNS_LIST="$_value $DNS_LIST" ;;
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
    _vpn_if="tun|wg|vpn|tap|ppp|openvpn|docker0|br-"

    if command -v ip > /dev/null 2>&1; then
        _iface="$(ip route show default \
            | awk '{print $5}' \
            | grep -Ev "${_vpn_if}" \
            | head -1)"
    elif command -v route > /dev/null 2>&1; then
        _iface="$(route -n get default 2>/dev/null \
            | awk '/interface:/{print $2; exit}' \
            | grep -Ev "${_vpn_if}" \
            | head -1)"
    fi

    if [ -n "$_iface" ]; then
        printf "%s\n" "$_iface"
    else
        _ret="$FAILURE"
    fi

    return "$_ret"
}

# Check if IMG_NAME exists
_podman_img_exists() {
    podman image exists "${IMG_NAME}"
}

# Get the repository of IMG_NAME
_podman_img_repo() {
    podman images "${IMG_NAME}" --format '{{.Repository}}'
}

# Get the list of available images for the project
_podman_list_img() {
    _list=""
    _list=$(
        podman images \
            --sort created \
            --format "{{.Repository}}:{{.Tag}}" \
            --filter "reference=${PRJ_ID}*"\
            --filter "dangling=false" |\
        while IFS= read -r line; do
            printf "%s" "$line "
        done
    )
    printf "%s" "$_list"
}

# Get the list of available containers
_podman_list_ctn() {
    _list=""
    _list=$(
        podman ps -a \
            --format "{{.Names}}" \
            --filter "name=${PRJ_ID}*" |\
        while IFS= read -r line; do
            printf "%s" "$line "
        done
    )
    printf "%s" "$_list"
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

# Copy an agent's skel files from ${IMG_D}/agents/<agent> into a mount dir,
# preserving their parent directory layout. Existing files are kept (cp -n),
# while existing folders are reused.
_copy_agent_files() {
    _src="${IMG_D}/agents/$1"
    _dst="$2"
    [ -d "$_src" ] || return "$SUCCESS"
    mkdir -p "$_dst"
    cp -rn "$_src/." "$_dst/"
    return "$SUCCESS"
}

# Bind and fill agent mounts for the auth, config, skills..., if applicable
_bind_agent_mounts() {
    _mount_d="${CACHE_D}/agents-mount"
    _home="/home/aiuser"
    _mounts=""
    _gemini_mounted=0
    _gcloud_mounted=0

    case " $AGENT " in *" copilot "*)
        mkdir -p "${_mount_d}/.config/gh" "${_mount_d}/.copilot"
        _mounts="$_mounts --volume $_mount_d/.config/gh:$_home/.config/gh:z"
        _mounts="$_mounts --volume $_mount_d/.copilot:$_home/.copilot:z"
    ;; esac
    
    # gemini + antigravity share ~/.gemini/
    case " $AGENT " in *" gemini "*|*" antigravity "*)
        if [ "$_gemini_mounted" = "0" ]; then
            mkdir -p "$_mount_d/.gemini"
            _mounts="$_mounts --volume $_mount_d/.gemini:$_home/.gemini:z"
            _gemini_mounted=1
        fi
    ;; esac

    # claude
    case " $AGENT " in *" claude "*)
        mkdir -p "$_mount_d/.claude"
        touch "$_mount_d/.claude.json"          # must exist as file before mount
        _mounts="$_mounts --volume $_mount_d/.claude:$_home/.claude:z"
        _mounts="$_mounts --volume $_mount_d/.claude.json:$_home/.claude.json:z"
    ;; esac

    # claude (Vertex) + opencode share ~/.config/gcloud/
    case " $AGENT " in *" claude "*|*" opencode "*)
        if [ "$_gcloud_mounted" = "0" ]; then
            mkdir -p "$_mount_d/.config/gcloud"
            _mounts="$_mounts \
--volume $_mount_d/.config/gcloud:$_home/.config/gcloud:z"
            _gcloud_mounted=1
        fi
    ;; esac

    # opencode
    case " $AGENT " in *" opencode "*)
        mkdir -p "$_mount_d/.config/opencode"
        _mounts="$_mounts \
--volume $_mount_d/.config/opencode:$_home/.config/opencode:z"
    ;; esac

    # hermes-agent
    case " $AGENT " in *" hermes-agent "*)
        mkdir -p "$_mount_d/.hermes"
        _mounts="$_mounts --volume $_mount_d/.hermes:$_home/.hermes:z"
    ;; esac

    # Seed each mounted config dir with the agent's skel files from the image.
    # Most agents map to ".<agent>", except antigravity (shares .gemini) and
    # hermes-agent (.hermes).
    for _agt in $AGENT; do
        case "$_agt" in
            antigravity)  _copy_agent_files "$_agt" "$_mount_d/.gemini" ;;
            hermes-agent) _copy_agent_files "$_agt" "$_mount_d/.hermes" ;;
            *)            _copy_agent_files "$_agt" "$_mount_d/.$_agt" ;;
        esac
    done

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
  -vv           Enable verbose and debug podman outputs
  --version     Show version information and exit
  -h, --help    Show this help message and exit

Actions:
  run           Run the sandbox with the specified agent
  build         Build the container image for the specified agent
                By default it bases from the registry: ${DEFAULT_IMG_REPO}
  clean         Remove generated container for the specified agent
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
  --dns        Defined DNS to use when using microvm. Can be set multiple times,
               default are 1.1.1.1 and 8.8.8.8
  --workspace, -w <dir>
               For 'run' action, Specify a custom workspace directory
               (default: ${SANDBOX_D_DEFAULT}) to mount in the sandbox at
               /home/aiuser/workspace.
  --full       Build fully the container image instead of refering to the one
               from registry ${DEFAULT_IMG_REPO}
  --all, -a    For 'clean' action, also remove home volume and auth tokens
  --image      For 'clean' action, Remove built images of an agent

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

    # Check scripts before continuing
    # TODO: Get the hooks from vendordir `/usr/etc/${PRJ_ID}/*`
    # TODO: Get the hooks from admin config `/etc/${PRJ_ID}/*`
    [ -n "${BUILD_HOOK_ARG}" ] && \
        _build_hook="$(_parse_hooks_f "${BUILD_HOOK_ARG}")"
    for _h in $_build_hook; do
        if ! _check_scripts "$_h"; then
            print_warning "malformated hook script: $_h"
            _ret="$FAILURE"
        fi
    done
    [ "${_ret}" = "$FAILURE" ] && return $_ret

    # Populate the build dir
    _build_d="${CACHE_D}/build"
    [ -d "${_build_d}" ] || mkdir -p "${_build_d}"
    cp -r "${IMG_D}/." "${_build_d}/"

    # Copy user hooks into the build context
    [ -n "$_build_hook" ] && {
        print_debug "Copying build hook(s): $_build_hook"
        for _h in $_build_hook; do
            cp "$_h" "${_build_d}/hooks/build/"
        done
    }

    if [ $BUILD_FULL -eq 1 ]; then
        _container_f="${_build_d}/Containerfile"
    else
        _container_f="${_build_d}/Containerfile.agent"
        sed -i "s|%%AGENT%%|$AGENT|g" "${_container_f}"
    fi
    print_info "Building container image ${IMG_NAME}:${IMG_TAG} ..."
    set --
    [ ${DEBUG} -eq 1 ] && set -- --log-level=debug
    set -- "$@" build --no-cache --rm \
        --build-arg "AGENT=\"${AGENT}\"" \
        --build-arg "IMG_TAG=${IMG_TAG}" \
        --build-arg "PKGS=\"${PKGS}\"" \
        --tag "${IMG_NAME}:${IMG_TAG}" \
        --tag "${IMG_NAME}:latest" \
        --file "${_container_f}" \
        "${_build_d}"
    _args=$*
    _cmd="podman ${_args}"
    [ ${VERBOSE} -eq 0 ] && _cmd="${_cmd} > /dev/null 2>&1"

    print_debug "$_cmd"
    if ! eval "$_cmd"; then
        print_error "Image build failed."
        _ret="$FAILURE"
    else
        print_info "Image built successfully."
    fi

    # clean up temporary hook files from build context
    [ -d "${_build_d}" ] && rm -r "${_build_d}"
    return "$_ret"
}

# callback for run action
run() {
    _ret="$SUCCESS"

    _verify_workspace_d || return "$FAILURE"
    
    _podman_cmd="podman"
    [ ${DEBUG} -eq 1 ] && _podman_cmd="podman --log-level=debug"

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
                    if ! ${_podman_cmd} exec -it "$CTN_NAME" bash; then
                        _ret="$FAILURE"
                    fi
                    [ "$(uname -s)" = "Darwin" ] && _macos_run_teardown
                    return "$_ret"
                fi
            };;
            initialized|created|configured|exited) {
                print_info "Starting container from '$STATE'..."
                if ! ${_podman_cmd} start -ai "$CTN_NAME"; then
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

    # Check if image is built locally
    _default_repo="${DEFAULT_IMG_REPO}/${IMG_NAME}"
    if ! _podman_img_exists ||\
       [ "$(_podman_img_repo)" = "${_default_repo}" ]; then
        IMG_NAME="${_default_repo}"
        print_info "Pulling image: ${IMG_NAME}..."
        if ! podman pull -q "${IMG_NAME}" > /dev/null 2>&1; then
            print_error "No Image built and cannot pull ${IMG_NAME}"
            return "$FAILURE"
        fi
    fi

    # Setup agents config
    _agent_mounts="$(_bind_agent_mounts)"

    # Setup run hooks
    # TODO: Get the hooks from vendordir `/usr/etc/${PRJ_ID}/*`
    # TODO: Get the hooks from admin config `/etc/${PRJ_ID}/*`
    _hooks_mount_d="${CACHE_D}/run-hooks"
    [ -d "${_hooks_mount_d}" ] && rm -r "${_hooks_mount_d}"
    mkdir -p "${_hooks_mount_d}"
    [ -n "${RUN_HOOK_ARG}" ] && \
        _run_hook="$(_parse_hooks_f "${RUN_HOOK_ARG}")"
    for _h in $_run_hook; do
        if ! _check_scripts "$_h"; then
            print_warning "malformated hook script: $_h"
            _ret="$FAILURE"
        fi
    done
    [ "${_ret}" = "$FAILURE" ] && return $_ret
    [ -n "$_run_hook" ] && {
        print_debug "Copying run hook(s): $_run_hook"
        for _h in $_run_hook; do
            cp "$_h" "${_hooks_mount_d}/"
        done
    }

    set --
    [ "$USE_MICROVM" = "1" ] && set -- --runtime krun
    set -- "$@" \
        --name "$CTN_NAME" \
        "${_agent_mounts}" \
        --volume "${_hooks_mount_d}:/usr/local/bin/${PRJ_ID}-run-hooks/:z" \
        --volume "$SANDBOX_D:/home/aiuser/workspace:z" \
        --tmpfs "/tmp:rw,nosuid,noexec,size=1g" \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --userns keep-id \
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
    if [ "$(uname -s)" = "Darwin" ]; then
        print_info "VM-layer nftables enforcement active."
        set -- "$@" --network pasta
    else
        print_info "Binding outbound to interface: $_iface"
        set -- "$@" --network "pasta:--outbound-if4,${_iface}"
        [ "$DNS_LIST" = "" ] && DNS_LIST="1.1.1.1 8.8.8.8"
        for _dns in $DNS_LIST; do
            set -- "$@" --dns "$_dns"
        done
    fi

    if [ "$USE_MICROVM" = "1" ]; then
        # Available on crun > 1.27, below /.krun_config.json in the image is
        # required
        set -- "$@" --annotation krun.ram_mib=8192 --annotation krun.cpus=4
    fi

    _args=$*
    print_info "Starting isolated container..."
    _cmd="${_podman_cmd} run -it $_args ${IMG_NAME}:latest"
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

    # Clean container(s)
    if [ $ALL -eq 1 ]; then
        _containers=$(_podman_list_ctn)
        for _ctn in ${_containers}; do
            if podman rm -f "$_ctn"; then
                print_info "Container ${_ctn} removed."
            else
                print_error "Failed to remove container '$_ctn'."
                _ret="$FAILURE"
            fi
        done
    else
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
        fi
    fi

    # Clean Cache
    if [ $ALL -eq 1 ]; then
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
        _agent_volume="$CACHE_D/agents-mount"
        if [ -d "$_agent_volume" ]; then
            print_info "Removing agent mount directory '$_agent_volume'..."
            rm -rf "$_agent_volume"
            print_info "Config agents cleaned."
        fi
        _hooks_volume="$CACHE_D/run-hooks"
        if [ -d "$_hooks_volume" ]; then
            print_info "Removing hooks mount directory '$_hooks_volume'..."
            rm -rf "$_hooks_volume"
            print_info "Hooks volume cleaned."
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

    # Clean images, if all has been given all images will be removed. If an
    # agent has been specified, the listing will show only related agent image.
    if [ ${CLEAN_IMG} -eq 1 ] || [ ${ALL} -eq 1 ]; then
        _images=$(_podman_list_img)
        echo "images=${_images}"
        # Protect from "all" not given, IMG_NAME whould list all.
        if [ ${ALL} -eq 0 ]; then
            _images=$(echo "${_images}" | tr ' ' '\n' | grep "${IMG_NAME}")
        fi
        echo "parsed images=${_images}"
        for _img in ${_images}; do
            podman image rm "${_img}"
        done
        print_info "All images related to ${IMG_NAME} has been removed."
    fi
    return "${_ret}"
}

# callback for status action
status() {
    printf "Images :\n"
    _images=$(_podman_list_img)
    if [ "${_images}" = "" ]; then
        printf "  None\n"
    else
        for _img in ${_images}; do
            printf "  - %s\n" "${_img}"
        done
    fi
    printf "Containers :\n"
    _containers=$(_podman_list_ctn)
    if [ "${_containers}" = "" ]; then
        printf "  None\n"
    else
        for _ctn in ${_containers}; do
            _status="$(podman inspect "${_ctn}" --format "{{.State.Status}}")"
            _ctn_img="$(podman inspect "${_ctn}" --format "{{.ImageName}}")"
            printf "  - %s [%s]\n" "${_ctn}" "${_status}"
            printf "      with %s\n" "${_ctn_img}"
        done
    fi
    exit ${SUCCESS}
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
        help|--help|-h)          usage;                     exit 0  ;;
        verbose|--verbose|-v)    VERBOSE=1;                 shift 1 ;;
        -vv)                     VERBOSE=1; DEBUG=1;        shift 1 ;;
        quiet|--quiet|-q)        QUIET=1;                   shift 1 ;;
        version|--version)       print_version;             exit 0  ;;
        run|build|clean|status)  ACTION="$1";               shift 1 ;;
        --no-microvm|no-microvm) USE_MICROVM=0;             shift 1 ;;
        --conf)                  CONF_P="$2";               shift 2 ;;
        --cache)                 CACHE_D="$2";              shift 2 ;;
        --build-hook)            BUILD_HOOK_ARG="$2";       shift 2 ;;
        --run-hook)              RUN_HOOK_ARG="$2";         shift 2 ;;
        --dns)                   DNS_LIST="$2 $DNS_LIST";   shift 2 ;;
        full|--full)             BUILD_FULL=1;              shift 1 ;;
        all|--all|-a)            ALL=1;                     shift 1 ;;
        --image)
            if [ "$ACTION" =  "clean" ]; then
                CLEAN_IMG=1;
            fi
            shift 1
            ;;
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
    # IF build is invoked, it should act like full argument.
    # Todo: Create the all image to export the full build for all agents
    BUILD_FULL=1
    AGENT="$TRUSTED_AGENTS"
fi

if ! eval "$ACTION"; then
    print_error "[✗] Action '$ACTION' failed."
    exit $FAILURE
else
    print_info "[✓] Done."
fi
