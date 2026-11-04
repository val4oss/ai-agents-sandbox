#!/usr/bin/env bash

# Redirect the whole podman state and the XDG dirs into a throw-away dir.

# Create the isolated podman/XDG environment. Call it from setup_file().
# ARGUMENTS:
#   1 - dir: empty directory that will hold every file of the environment
isolate_podman() {
    local _iso_d="$1" _run_d _got

    # Real state, read BEFORE overriding anything
    REAL_HOME="$HOME"
    REAL_GRAPHROOT="$(podman info --format '{{.Store.GraphRoot}}')"
    REAL_IMAGES="$(podman images -q | sort -u | tr '\n' ' ')"
    export REAL_HOME REAL_GRAPHROOT REAL_IMAGES

    # Short path: AF_UNIX sockets (pause, netns) are limited to 108 chars
    _run_d="$(mktemp -d /tmp/glt.XXXXXX)" && chmod 700 "$_run_d" || return 1
    mkdir -p "$_iso_d"/home "$_iso_d"/config "$_iso_d"/cache \
        "$_iso_d"/data "$_iso_d"/graph || return 1

    {
        printf '[storage]\ndriver = "overlay"\n'
        # rootless podman ignores 'graphroot', it reads 'rootless_storage_path'
        printf 'graphroot = "%s/graph"\n' "$_iso_d"
        printf 'rootless_storage_path = "%s/graph"\n' "$_iso_d"
        printf 'runroot = "%s/containers"\n' "$_run_d"
        if [ "${GLAIPNIR_TEST_SHARE_IMAGES:-0}" = 1 ]; then
            # read-only reuse of the user's images: no pull, no write
            printf '[storage.options]\nadditionalimagestores = ["%s"]\n' \
                "$REAL_GRAPHROOT"
        fi
    } > "$_iso_d/storage.conf"
    : > "$_iso_d/containers.conf"
    # Also install it at the rootless default location: some versions ignore
    # CONTAINERS_STORAGE_CONF
    mkdir -p "$_iso_d/config/containers" || return 1
    cp "$_iso_d/storage.conf" "$_iso_d/config/containers/storage.conf" ||
        return 1

    export ISO_RUN_D="$_run_d"
    export CONTAINERS_STORAGE_CONF="$_iso_d/storage.conf"
    export CONTAINERS_CONF="$_iso_d/containers.conf"
    export XDG_RUNTIME_DIR="$_run_d"
    export HOME="$_iso_d/home"
    export XDG_CONFIG_HOME="$_iso_d/config"
    export XDG_CACHE_HOME="$_iso_d/cache"
    export XDG_DATA_HOME="$_iso_d/data"

    # Fail closed: never go on if podman still points at the real store
    _got="$(podman info --format '{{.Store.GraphRoot}}')"
    if [ "$(realpath "$_got")" != "$(realpath "$_iso_d/graph")" ]; then
        printf 'podman isolation failed: graphroot is "%s", expected "%s"\n' \
            "$_got" "$_iso_d/graph" >&2
        return 1
    fi
}

# Remove everything created by isolate_podman. Call it from teardown_file().
# ARGUMENTS:
#   1 - dir: the directory given to isolate_podman
cleanup_podman() {
    local _iso_d="$1" _pid_f="${ISO_RUN_D:-/nonexistent}/libpod/tmp/pause.pid"
    local _pid=""

    # read the pause pid before the runtime dir goes away
    if [ -f "$_pid_f" ]; then
        _pid="$(cat "$_pid_f")"
    fi

    podman rm -fa >/dev/null 2>&1 || true
    # graph files belong to sub-uids: only 'podman unshare' can delete them
    podman unshare rm -rf "$_iso_d" "${ISO_RUN_D:-}" 2>/dev/null || true
    # stop the rootless pause process
    if [ -n "$_pid" ]; then
        kill "$_pid" 2>/dev/null || true
    fi
    rm -rf "$_iso_d" "${ISO_RUN_D:-}" 2>/dev/null || true
    return 0
}
