#!/usr/bin/env bash

# Run glaipnir against a fake podman: nothing is started, the arguments given
# to 'podman run' are recorded and can be checked.

# Prepare the fake environment. Call it from setup().
# ARGUMENTS:
#   1 - dir: empty directory holding HOME, the XDG dirs and the logs
stub_env() {
    local _d="$1"

    mkdir -p "$_d/home/ws" "$_d/config" "$_d/cache" "$_d/data" || return 1
    export HOME="$_d/home"
    export XDG_CONFIG_HOME="$_d/config"
    export XDG_CACHE_HOME="$_d/cache"
    export XDG_DATA_HOME="$_d/data"
    export PODMAN_STUB_LOG="$_d/podman.log"
    export PODMAN_STUB_RUN_LOG="$_d/run.log"
    export PODMAN_STUB_BUILD_LOG="$_d/build.log"
    export PODMAN_STUB_BUILD_CTX="$_d/build-ctx.log"
    unset PODMAN_STUB_BUILD_FAIL PODMAN_STUB_IMAGES PODMAN_STUB_IMG_REPO \
        PODMAN_STUB_NO_IMAGE PODMAN_STUB_CONTAINERS PODMAN_STUB_FAIL \
        PODMAN_STUB_RUN_HOOK SOCAT_STUB_LOG SOCAT_PID_F PODMAN_STUB_VOLUMES
    # Workspace to give to '--workspace', canonical path
    WS="$(realpath "$HOME/ws")"
    export WS

    # The stubs must come first: the real podman must never be reached
    PATH="$(cd "$BATS_TEST_DIRNAME/test_helper/stubs" && pwd):$PATH"
    export PATH

    # Variables that would change the command built by glaipnir
    unset GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_REGION VERTEX_LOCATION \
        CLOUD_ML_REGION ANTHROPIC_VERTEX_PROJECT_ID ANTHROPIC_VERTEX_LOCATION \
        GCLOUD_PROJECT GCLOUD_REGION GOOGLE_APPLICATION_CREDENTIALS \
        GCLOUD_STUB_PROJECT GCLOUD_STUB_LOG
}

# Run 'glaipnir run' in the fake environment WITHOUT microVM. The microVM mode
# depends on the host (krun, /dev/kvm, kvm group, possible sudo prompt), so the
# general tests stay in container mode to build a reproducible command.
# ARGUMENTS:
#   @ - agents and options given to glaipnir
glaipnir_run_no_microvm() {
    run "$BIN_TEST" run --no-microvm --workspace "$WS" "$@"
}

# Run 'glaipnir run' in the fake environment WITH microVM (the default mode).
# Skip the test when the host cannot run microVMs: glaipnir would then fall back
# to the container mode.
# ARGUMENTS:
#   @ - agents and options given to glaipnir
glaipnir_run_microvm() {
    [ -x /usr/bin/krun ] || skip "krun is not installed"
    [ -c /dev/kvm ] || skip "KVM is not available"
    id -Gn | tr ' ' '\n' | grep -qx kvm || skip "user not in the kvm group"
    run "$BIN_TEST" run --workspace "$WS" "$@" </dev/null
}

# Print the values of an option of 'podman run', one per line.
# ARGUMENTS:
#   1 - opt: option name, e.g. --volume
run_opt_values() {
    awk -v o="$1" '$0 == o { getline v; print v }' "$PODMAN_STUB_RUN_LOG"
}

# Print the whole command recorded, for the failure messages.
_run_log() {
    printf 'podman run recorded arguments:\n%s\n' \
        "$(cat "$PODMAN_STUB_RUN_LOG" 2>/dev/null)"
}

# Fail unless 'podman run' got the exact argument.
assert_run_arg() {
    grep -Fxq -- "$1" "$PODMAN_STUB_RUN_LOG" ||
        fail "missing argument '$1'"$'\n'"$(_run_log)"
}

# Fail if 'podman run' got the exact argument.
refute_run_arg() {
    ! grep -Fxq -- "$1" "$PODMAN_STUB_RUN_LOG" ||
        fail "unexpected argument '$1'"$'\n'"$(_run_log)"
}

# Fail unless 'podman run' got the option with exactly this value.
# ARGUMENTS:
#   1 - opt: option name
#   2 - value: expected value
assert_run_opt() {
    run_opt_values "$1" | grep -Fxq -- "$2" ||
        fail "missing '$1 $2'"$'\n'"$(_run_log)"
}

# Fail unless 'podman run' got the option with a value matching the regex.
# ARGUMENTS:
#   1 - opt: option name
#   2 - regex: extended regular expression
assert_run_opt_match() {
    run_opt_values "$1" | grep -Eq -- "$2" ||
        fail "no '$1' value matching '$2'"$'\n'"$(_run_log)"
}

# Fail if 'podman run' got the option with a value matching the regex.
refute_run_opt_match() {
    ! run_opt_values "$1" | grep -Eq -- "$2" ||
        fail "unexpected '$1' value matching '$2'"$'\n'"$(_run_log)"
}

# Fail unless 'podman run' mounts the default workspace of glaipnir, which is
# the fallback of a refused workspace.
assert_workspace_fallback() {
    assert_run_opt --volume \
        "${XDG_CACHE_HOME}/glaipnir/workspace:/home/aiuser/workspace:z"
}

# Fail if 'podman run' mounts the given host path, whatever the destination.
# ARGUMENTS:
#   1 - src: host path that must not be mounted
refute_run_mount_of() {
    run_opt_values --volume | cut -d: -f1 | grep -Fxq -- "$1" &&
        fail "mounted: $1"$'\n'"$(_run_log)"
    return 0
}

# Run 'glaipnir build' in the fake environment.
# ARGUMENTS:
#   @ - agents and options given to glaipnir
glaipnir_build() {
    run "$BIN_TEST" build "$@"
}

# Print the values of an option of 'podman build', one per line.
# ARGUMENTS:
#   1 - opt: option name, e.g. --build-arg
build_opt_values() {
    awk -v o="$1" '$0 == o { getline v; print v }' "$PODMAN_STUB_BUILD_LOG"
}

# Print the whole command recorded, for the failure messages.
_build_log() {
    printf 'podman build recorded arguments:\n%s\n' \
        "$(cat "$PODMAN_STUB_BUILD_LOG" 2>/dev/null)"
}

# Fail unless 'podman build' got the exact argument.
assert_build_arg() {
    grep -Fxq -- "$1" "$PODMAN_STUB_BUILD_LOG" ||
        fail "missing argument '$1'"$'\n'"$(_build_log)"
}

# Fail unless 'podman build' got the option with exactly this value.
# ARGUMENTS:
#   1 - opt: option name
#   2 - value: expected value
assert_build_opt() {
    build_opt_values "$1" | grep -Fxq -- "$2" ||
        fail "missing '$1 $2'"$'\n'"$(_build_log)"
}

# Fail unless 'podman build' got the option with a value matching the regex.
# ARGUMENTS:
#   1 - opt: option name
#   2 - regex: extended regular expression
assert_build_opt_match() {
    build_opt_values "$1" | grep -Eq -- "$2" ||
        fail "no '$1' value matching '$2'"$'\n'"$(_build_log)"
}

# Fail if 'podman build' was called.
refute_build_called() {
    [ ! -s "$PODMAN_STUB_BUILD_LOG" ] ||
        fail "podman build was called"$'\n'"$(_build_log)"
}

# Add a container to the fake podman.
# ARGUMENTS:
#   1 - name: name of the container
#   2 - state: state given by 'podman inspect' (running, exited, paused...)
#   3 - runtime: OCI runtime, runc by default
#   4 - image: image name/id, optional
stub_container() {
    export PODMAN_STUB_CONTAINERS="$BATS_TEST_TMPDIR/containers"
    printf '%s %s %s %s\n' "$1" "$2" "${3:-runc}" "${4:-}" \
        >> "$PODMAN_STUB_CONTAINERS"
}

# Add an image to the fake podman.
# ARGUMENTS:
#   1 - repo: image repository
#   2 - tag: image tag, latest by default
#   3 - id: image ID, img123 by default
stub_image() {
    export PODMAN_STUB_IMAGES="$BATS_TEST_TMPDIR/images"
    printf '%s %s %s\n' "$1" "${2:-latest}" "${3:-img123}" \
        >> "$PODMAN_STUB_IMAGES"
}

# Add a volume to the fake podman.
# ARGUMENTS:
#   1 - name: name of the volume
stub_volume() {
    export PODMAN_STUB_VOLUMES="$BATS_TEST_TMPDIR/volumes"
    printf '%s\n' "$1" >> "$PODMAN_STUB_VOLUMES"
}

# Fail unless podman got exactly this call (all its arguments on one line).
# ARGUMENTS:
#   @ - the arguments of the call
assert_podman_call() {
    grep -Fxq -- "$*" "$PODMAN_STUB_LOG" ||
        fail "missing podman call '$*'"$'\n'"$(cat "$PODMAN_STUB_LOG")"
}

# Fail if podman got a call starting with these arguments.
# ARGUMENTS:
#   @ - the beginning of the call
refute_podman_call() {
    ! awk -v p="$*" 'index($0, p) == 1 { f = 1 } END { exit !f }' \
        "$PODMAN_STUB_LOG" ||
        fail "unexpected podman call '$*'"$'\n'"$(cat "$PODMAN_STUB_LOG")"
}

# Fail if podman got exactly this call.
# ARGUMENTS:
#   @ - the arguments of the call
refute_podman_exact_call() {
    ! grep -Fxq -- "$*" "$PODMAN_STUB_LOG" ||
        fail "unexpected podman call '$*'"$'\n'"$(cat "$PODMAN_STUB_LOG")"
}

# Fail if 'podman run' was called.
refute_run_called() {
    [ ! -s "$PODMAN_STUB_RUN_LOG" ] ||
        fail "podman run was called"$'\n'"$(_run_log)"
}

# Put a fake socat first in the PATH. Like the real listener, it stays alive
# and the PID of the process is written in $SOCAT_PID_F. Call
# stub_kill_fake_socat from teardown() to never leave it behind.
stub_fake_socat() {
    mkdir -p "$BATS_TEST_TMPDIR/fake"
    cat > "$BATS_TEST_TMPDIR/fake/socat" << 'SOCAT'
#!/bin/sh
if [ -n "${SOCAT_STUB_LOG:-}" ]; then
    printf '%s\n' "$@" > "$SOCAT_STUB_LOG"
fi
printf '%s\n' "$$" > "$SOCAT_PID_F"
exec sleep 300
SOCAT
    chmod +x "$BATS_TEST_TMPDIR/fake/socat"
    export SOCAT_PID_F="$BATS_TEST_TMPDIR/socat.pid"
    export SOCAT_STUB_LOG="$BATS_TEST_TMPDIR/socat.log"
    PATH="$BATS_TEST_TMPDIR/fake:$PATH"
    export PATH
}

# Kill the fake socat if it still runs. Fails if it did.
stub_kill_fake_socat() {
    local _pid
    [ -s "${SOCAT_PID_F:-/nonexistent}" ] || return 0
    _pid="$(cat "$SOCAT_PID_F")"
    if kill -0 "$_pid" 2>/dev/null; then
        kill "$_pid"
        return 1
    fi
    return 0
}
