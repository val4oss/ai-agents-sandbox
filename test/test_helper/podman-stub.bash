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
    # Workspace to give to '--workspace', canonical path
    WS="$(realpath "$HOME/ws")"
    export WS

    # The stubs must come first: the real podman must never be reached
    PATH="$(cd "$BATS_TEST_DIRNAME/test_helper/stubs" && pwd):$PATH"
    export PATH

    # Variables that would change the command built by glaipnir
    unset GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_REGION VERTEX_LOCATION \
        CLOUD_ML_REGION ANTHROPIC_VERTEX_PROJECT_ID ANTHROPIC_VERTEX_LOCATION \
        GCLOUD_PROJECT GCLOUD_REGION GOOGLE_APPLICATION_CREDENTIALS
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
