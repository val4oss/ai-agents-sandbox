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
VALID_AGENTS="copilot claude gemini opencode"
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

# check if agent is valide
_valide_agent() {
    _ret="$FAILURE"
    for _agt_v in $VALID_AGENTS; do
        if [ "$AGENT" = "$_agt_v" ]; then
            _ret="$SUCCESS"
            break
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
    ip route show default \
        | awk '{print $5}' \
        | grep -Ev 'tun|wg|vpn|tap|ppp' \
        | head -1
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
  $VALID_AGENTS
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
        set -- "$@" --annotation krun.ram_mib=4096 --annotation krun.cpus=2
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
        help|--help|-h)         usage;         exit 0  ;;
        verbose|--verbose|-v)   VERBOSE=1;     shift 1 ;;
        quiet|--quiet|-q)       QUIET=1;       shift 1 ;;
        version|--version)      print_version; exit 0  ;;
        run|build|clean|status) ACTION="$1";   shift 1 ;;
        no-microvm)             USE_MICROVM=0; shift 1 ;;
        all|--all|-a)           ALL=true;      shift 1 ;;
        --workspace|-w)
            if [ -z "$2" ]; then
                print_error "Error: $1 requires an argument."
                exit 1
            fi
            SANDBOX_D="$2"
            shift 2  # Shift past both the flag and its value
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
        print_error "Unknown agent: '$AGENT'. Valid agents: $VALID_AGENTS"
        exit $FAILURE
    else
        IMG_NAME="${IMG_NAME}-${AGENT}"
        CTN_NAME="${CTN_NAME}-${AGENT}"
    fi
else
    AGENT="$VALID_AGENTS"
fi

if ! eval "$ACTION"; then
    print_error "[✗] Action '$ACTION' failed."
    exit $FAILURE
else
    print_info "[✓] Done."
fi
