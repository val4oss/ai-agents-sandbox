#!/bin/sh

SCRIPT_D="$(dirname "$0")"
ROOT_D="$(cd "${SCRIPT_D}/.." && pwd)"
SANDBOX_DIR="$ROOT_D/sandbox"
CONTAINER_NAME="ai-agents-sandbox"
IMAGE_NAME="ai-agents-sandbox"
KRUN_BIN="/usr/bin/krun"

VALID_AGENTS="$(grep "^AGENTS := " Makefile | sed 's/.*:= //')"
validate_agent() {
    _agent="$1"
    for _agt_v in $VALID_AGENTS; do
        [ "$_agent" = "$_agt_v" ] && return 0
    done
    echo "[✗] Unknown agent: '$_agent'. Valid agents: $VALID_AGENTS"
    exit 1
}

AGENT=""
USE_MICROVM=1

for _arg in "$@"; do
    case "$_arg" in
        no-microvm) USE_MICROVM=0 ;;
        *)          AGENT="$_arg" ;;
    esac
done

if [ -n "$AGENT" ]; then
    validate_agent "$AGENT"
    IMAGE_NAME="${IMAGE_NAME}-${AGENT}"
    CONTAINER_NAME="${CONTAINER_NAME}-${AGENT}"
fi

# Hint shown in every microVM error message
_fallback="make run"
[ -n "$AGENT" ] && _fallback="${_fallback} ${AGENT}"
_fallback="${_fallback} no-microvm"

check_microvm() {
    if [ ! -x "$KRUN_BIN" ]; then
        printf '[!] krun not found at %s\n' "$KRUN_BIN"
        printf '    Install it  : install krun via your package manager\n'
        printf '    Skip microVM: %s\n' "$_fallback"
        exit 1
    fi

    if [ ! -c /dev/kvm ]; then
        printf '[!] /dev/kvm not found — KVM is not available on this host\n'
        printf '    Enable it   : load the kvm_amd or kvm_intel kernel module\n'
        printf '    Skip microVM: %s\n' "$_fallback"
        exit 1
    fi

    if ! id -Gn | tr ' ' '\n' | grep -qx kvm; then
        printf '[!] User "%s" is not in the kvm group\n' "$(id -un)"
        printf '    Run `sudo usermod -aG kvm %s`  (then relogin)\n' "$(id -un)"
        printf '    Skip microVM with: %s\n' "$_fallback"
        exit 1
    fi

    # Nested-virtualisation check — warn only, does not abort
    _in_vm=0
    if [ -f /sys/class/dmi/id/sys_vendor ]; then
        _vendor="$(cat /sys/class/dmi/id/sys_vendor)"
        case "$_vendor" in
            *QEMU*|*KVM*|*VMware*|*VirtualBox*|*Xen*|*Microsoft*) _in_vm=1 ;;
        esac
    fi
    grep -q "hypervisor" /proc/cpuinfo 2>/dev/null && _in_vm=1

    if [ "$_in_vm" = "1" ]; then
        _nested_amd=""
        _nested_intel=""
        _nested_arm=""
        [ -f /sys/module/kvm_amd/parameters/nested ] &&\
            _nested_amd="$(cat /sys/module/kvm_amd/parameters/nested)"
        [ -f /sys/module/kvm_intel/parameters/nested ] &&\
            _nested_intel="$(cat /sys/module/kvm_intel/parameters/nested)"
        [ -f /sys/module/kvm/parameters/nested ] &&\
            _nested_arm="$(cat /sys/module/kvm/parameters/nested)"
        if [ "$_nested_amd" != "1" ] && \
           [ "$_nested_intel" != "Y" ] && [ "$_nested_intel" != "1" ] && \
           [ "$_nested_arm"   != "Y" ] && [ "$_nested_arm"   != "1" ]; then
            printf '[!] Running inside a VM — nested virtualisation not detected\n'
            printf '    krun may fail; enable nested virt on your hypervisor \n'
            printf '    or skip with: %s\n' "$_fallback"
        fi
    fi
}

# Determine runtime mode
USE_KRUN=0
CONF_FILE="$SCRIPT_D/containers.conf"

if [ "$(uname -s)" = "Darwin" ] && [ "$USE_MICROVM" = "1" ]; then
    printf '[!] macOS detected — KVM is not available;\n'
    printf '    -> running without microVM isolation\n'
    printf '    -> Podman Machine already provides a VM boundary via Apple\n'
    printf '       Hypervisor.framework\n'
    USE_MICROVM=0
fi

if [ "$USE_MICROVM" = "1" ]; then
    check_microvm
    USE_KRUN=1
    CONF_FILE="$SCRIPT_D/containers-krun.conf"
    printf '[*] MicroVM isolation enabled (krun)\n'
else
    printf '[*] MicroVM isolation disabled\n'
fi

export CONTAINERS_CONF="$CONF_FILE"

# Resume a stopped container (auth state preserved)
if podman container exists "$CONTAINER_NAME"; then
    STATE=$(podman inspect "$CONTAINER_NAME" --format '{{.State.Status}}')
    if [ "$STATE" = "running" ]; then
        echo "[*] Attaching to running container..."
        podman exec -it "$CONTAINER_NAME" bash
        exit 0
    elif [ "$STATE" = "exited" ]; then
        echo "[*] Resuming existing container (auth preserved)..."
        podman start -ai "$CONTAINER_NAME"
        exit 0
    fi
fi

echo "[*] Creating isolated container..."
set -- \
    --name "$CONTAINER_NAME" \
    --volume "$SANDBOX_DIR":/home/aiuser:z \
    --tmpfs /tmp:rw,noexec,nosuid,size=1g

if [ "$USE_KRUN" = "1" ]; then
    set -- --runtime "$KRUN_BIN" --annotation io.krun.memory=2048 "$@"
fi

podman run -it "$@" "${IMAGE_NAME}:latest"
