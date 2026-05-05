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
SANDBOX_D="$ROOT_D/sandbox"

# Container variables
IMG_NAME="ai-agents-sandbox"
CTN_NAME="ai-agents-sandbox"
IMG_TAG="0.1.0"
VALID_AGENTS="copilot claude gemini"

# argument variables
AGENT=""
USE_MICROVM=1
ACTION=""
ALL=false
TOOLS_NEEDED="podman sed grep"

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

# update version in entrypoint.sh
_update_entrypoint_version() {
    sed -i\
        "s/AI Agents Sandbox v[0-9]\+\.[0-9]\+\.[0-9]\+/AI Agents Sandbox v${IMG_TAG}/g"\
        "${IMG_D}/scripts/entrypoint.sh"
}

# update version in Containerfile
_update_containerfile_version() {
    sed -i\
        "s/version=\"[0-9]\+\.[0-9]\+\.[0-9]\+\"/version=\"${IMG_TAG}\"/g" \
        "${IMG_D}/Containerfile"
}

_check_microvm() {
    _ret="$SUCCESS"
    if [ ! -x "/usr/bin/krun" ]; then
        print_warning "krun not found at /usr/bin/krun."
        print_warning "     -> Install it via your package manager."
        _ret="$FAILURE"
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
    _update_entrypoint_version
    _update_containerfile_version
    if ! podman build \
        --build-arg "AGENT=${AGENT}" \
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
    # Resume a stopped container
    if podman container exists "$CTN_NAME"; then
        STATE=$(podman inspect "$CTN_NAME" --format '{{.State.Status}}')
        case "$STATE" in
            running) {
                print_info "Attaching to running container..."
                podman exec -it "$CTN_NAME" bash
                return "$SUCCESS"
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

    if [ "$(uname -s)" = "Darwin" ] && [ "$USE_MICROVM" = "1" ]; then
        print_warning "[!] macOS detected — KVM is not available;"
        print_warning "    -> running without microVM isolation"
        print_warning "    -> Podman Machine already provides a VM boundary via\
 Apple"
        print_warning "       Hypervisor.framework"
        USE_MICROVM=0
    fi

    if [ "$USE_MICROVM" -eq 1 ]; then
        if ! _check_microvm; then
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
    else
        TOOLS_NEEDED="$TOOLS_NEEDED slirp4netns"
    fi
    if ! _check_tools_needed; then
        print_error "Required tools for the selected isolation are missing."
        print_error "Please install them and try again."
        return "$FAILURE"
    fi

    set --
    [ "$USE_MICROVM" = "1" ] && set -- --runtime krun
    set -- "$@" \
        --name "$CTN_NAME" \
        --volume "$SANDBOX_D:/home/aiuser:z" \
        --tmpfs "/tmp:rw,nosuid,size=1g" \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --userns=keep-id \
        --hostname ai-sandbox \
        --pids-limit 1024
    if [ "$USE_MICROVM" = "1" ]; then
        set -- "$@" --annotation krun.ram_mib=4096 --annotation krun.cpus=2
    else
        set -- "$@" --network slirp4netns
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
    print_info "Cleaning containers for agent '${AGENT}'..."
    if podman container exists "$CTN_NAME"; then
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
        print_info "Cleaning auth tokens and workspace for agent '${AGENT}'..."
        rm -rf \
            "$SANDBOX_D/.config/gh" \
            "$SANDBOX_D/.local" \
            "$SANDBOX_D/.gemini" \
            "$SANDBOX_D/.claude" \
            "$SANDBOX_D/.copilot" \
            "$SANDBOX_D/.bash_history" \
            "$SANDBOX_D/venv" \
            "$SANDBOX_D/.gitconfig" \
            "$SANDBOX_D/workspace"
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
    usage & exit 2
fi
case "$1" in
    help|--help|-h)        usage ;          exit 0  ;;
    verbose|--verbose|-v)  VERBOSE=1;       shift 1 ;;
    quiet|--quiet|-q)      QUIET=1;         shift 1 ;;
    version|--version)     print_version;   exit 0  ;;
esac

# get actions/agents/options
for _arg in "$@"; do
    case "$_arg" in
        run|build|clean|status) ACTION="$_arg" ;;
        no-microvm)             USE_MICROVM=0  ;;
        all|--all|-a)           ALL=true       ;;
        *)                      AGENT="$_arg"  ;;
    esac
done

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
