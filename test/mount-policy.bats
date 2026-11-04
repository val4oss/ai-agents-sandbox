#!/usr/bin/env bats

# Policy applied to the host directories glaipnir mounts or writes to: the
# workspace, the cache and the data directory. Only the paths under HOME, /tmp,
# /var/tmp and /opt are allowed, and never HOME itself. A refused path falls
# back to the default one.
# podman is a stub (test/test_helper/stubs): nothing is started.

setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
}

# Never create directories at the root of a real system.
_skip_if_root() {
    [ "$(id -u)" -ne 0 ] || skip "must not run as root"
}

# ==========
# Workspace
# ----------

@test "workspace under HOME is accepted and mounted" {
    mkdir -p "$HOME/project"
    glaipnir_run_no_microvm claude --workspace "$HOME/project"
    assert_success
    assert_run_opt --volume "${HOME}/project:/home/aiuser/project:z"
}

@test "missing workspace under HOME is created" {
    glaipnir_run_no_microvm claude --workspace "$HOME/new/sub"
    assert_success
    [ -d "$HOME/new/sub" ]
    assert_run_opt --volume "${HOME}/new/sub:/home/aiuser/new/sub:z"
}

@test "workspace /tmp subdirectory is accepted" {
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    glaipnir_run_no_microvm claude --workspace "$BATS_TEST_TMPDIR/elsewhere"
    assert_success
    assert_run_opt_match --volume \
        "^$(realpath "$BATS_TEST_TMPDIR")/elsewhere:/home/aiuser/"
}

@test "workspace HOME itself falls back to the default workspace" {
    glaipnir_run_no_microvm claude --workspace "$HOME"
    assert_success
    assert_workspace_fallback
    refute_run_mount_of "$HOME"
}

@test "workspace outside the allowed paths falls back" {
    for _bad in / /etc /root /usr /var/lib /proc /sys /dev; do
        glaipnir_run_no_microvm claude --workspace "$_bad"
        assert_success
        assert_workspace_fallback
        refute_run_mount_of "$_bad"
    done
}

@test "workspace on a whole allowed root falls back" {
    for _bad in /tmp /var/tmp /opt; do
        glaipnir_run_no_microvm claude --workspace "$_bad"
        assert_success
        assert_workspace_fallback
        refute_run_mount_of "$_bad"
    done
}

@test "workspace that is a file falls back" {
    touch "$HOME/afile"
    glaipnir_run_no_microvm claude --workspace "$HOME/afile"
    assert_success
    assert_workspace_fallback
    refute_run_mount_of "$HOME/afile"
}

@test "workspace symlink to a forbidden path falls back" {
    ln -s /etc "$HOME/link"
    glaipnir_run_no_microvm claude --workspace "$HOME/link"
    assert_success
    assert_workspace_fallback
    refute_run_mount_of "$HOME/link"
    refute_run_mount_of /etc
}

@test "workspace .. traversal to a forbidden path falls back" {
    glaipnir_run_no_microvm claude \
        --workspace "$HOME/../../../../../../../../etc"
    assert_success
    assert_workspace_fallback
    refute_run_mount_of /etc
}

@test "workspace ~ is expanded to HOME" {
    glaipnir_run_no_microvm claude --workspace '~/tilde'
    assert_success
    assert_run_opt --volume "${HOME}/tilde:/home/aiuser/tilde:z"
}

@test "workspace without argument is an error" {
    run "$BIN_TEST" run claude --no-microvm --workspace
    assert_failure 1
    [ ! -e "$PODMAN_STUB_RUN_LOG" ]
}

@test "other options without argument are errors" {
    for _opt in --ro-mount --data-dir --cmd -w; do
        run "$BIN_TEST" run claude --no-microvm "$_opt"
        assert_failure 1
        [ ! -e "$PODMAN_STUB_RUN_LOG" ]
    done
}

@test "default workspace being HOME makes run fail, HOME is never mounted" {
    export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/c"
    export HOME="$XDG_CACHE_HOME/glaipnir/workspace"
    mkdir -p "$HOME"
    glaipnir_run_no_microvm claude --workspace /etc
    assert_failure 1
    assert_output --partial "Default sandbox workspace points to HOME"
    [ ! -e "$PODMAN_STUB_RUN_LOG" ]
}

# =========
# Warnings
# ---------

@test "refused workspace is reported with the fallback used" {
    glaipnir_run_no_microvm claude --workspace /etc
    assert_success
    assert_output --partial "Mounting from /etc is not allowed"
    assert_output --partial "Falling back to default workspace: \
'${XDG_CACHE_HOME}/glaipnir/workspace'"
}

@test "refused HOME workspace is reported" {
    glaipnir_run_no_microvm claude --workspace "$HOME"
    assert_success
    assert_output --partial "Mounting from ${HOME} is forbidden"
}

@test "refused hidden workspace is reported" {
    glaipnir_run_no_microvm claude --workspace "$HOME/.ssh"
    assert_success
    assert_output --partial "Mounting from ${HOME}/.ssh is forbidden (hidden)"
}

@test "refused cache is reported with the fallback used" {
    glaipnir_run_no_microvm claude --cache /etc/glaipnir-cache
    assert_success
    assert_output --partial "Mounting from /etc/glaipnir-cache is not allowed"
    assert_output --partial \
        "Falling back to default cache: '${XDG_CACHE_HOME}/glaipnir'"
}

@test "refused data dir is reported with the fallback used" {
    _seed_agents_mount
    run "$BIN_TEST" save-data --data-dir "$HOME"
    assert_success
    assert_output --partial "Mounting from ${HOME} is forbidden"
    assert_output --partial \
        "Falling back to default data dir: '${XDG_DATA_HOME}/glaipnir'"
}

# =====
# Cache
# -----

@test "cache under HOME is used for the agents mounts" {
    glaipnir_run_no_microvm claude --cache "$HOME/mycache"
    assert_success
    assert_run_opt_match --volume "^${HOME}/mycache/agents-mount/\.claude:"
    [ -d "$HOME/mycache/agents-mount" ]
}

@test "cache outside the allowed paths falls back to the default" {
    glaipnir_run_no_microvm claude --cache /etc/glaipnir-cache
    assert_success
    assert_run_opt_match --volume \
        "^${XDG_CACHE_HOME}/glaipnir/agents-mount/\.claude:"
    refute_run_opt_match --volume '^/etc'
}

@test "cache HOME itself falls back to the default" {
    glaipnir_run_no_microvm claude --cache "$HOME"
    assert_success
    assert_run_opt_match --volume \
        "^${XDG_CACHE_HOME}/glaipnir/agents-mount/\.claude:"
    [ ! -e "$HOME/agents-mount" ]
}

# ========
# Data dir
# --------

# save-data needs an agents configuration to archive
_seed_agents_mount() {
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount"
    echo test > "$XDG_CACHE_HOME/glaipnir/agents-mount/file"
}

@test "data dir under HOME is used to save the archive" {
    _seed_agents_mount
    run "$BIN_TEST" save-data --data-dir "$HOME/saved"
    assert_success
    run find "$HOME/saved" -name 'glaipnir-data-*.tar.gz'
    assert_output --regexp 'glaipnir-data-.*\.tar\.gz'
}

@test "data dir HOME itself falls back to the default data dir" {
    _seed_agents_mount
    run "$BIN_TEST" save-data --data-dir "$HOME"
    assert_success
    run find "$XDG_DATA_HOME/glaipnir" -name 'glaipnir-data-*.tar.gz'
    assert_output --regexp 'glaipnir-data-.*\.tar\.gz'
    run find "$HOME" -maxdepth 1 -name 'glaipnir-data-*'
    assert_output ""
}

@test "clean-data never removes HOME" {
    mkdir -p "$XDG_DATA_HOME/glaipnir"
    touch "$HOME/canary" "$XDG_DATA_HOME/glaipnir/file"
    run "$BIN_TEST" clean-data --data-dir "$HOME"
    assert_success
    [ -e "$HOME/canary" ]
    # the fallback, default data dir, is the one cleaned
    [ ! -e "$XDG_DATA_HOME/glaipnir" ]
}

# ==============
# Path matching
# --------------

@test "workspace sharing only the prefix of an allowed path falls back" {
    _skip_if_root
    for _bad in /tmpevil /optional /var/tmpfoo; do
        glaipnir_run_no_microvm claude --workspace "$_bad"
        assert_success
        assert_workspace_fallback
        refute_run_mount_of "$_bad"
    done
}

@test "workspace in a hidden directory of HOME falls back" {
    for _bad in .ssh .gnupg .config .hidden project/.git .a/b/c; do
        glaipnir_run_no_microvm claude --workspace "$HOME/$_bad"
        assert_success
        assert_workspace_fallback
        refute_run_mount_of "$HOME/$_bad"
        [ ! -e "$HOME/$_bad" ]
    done
}

@test "fallback workspace may live in a hidden directory of HOME" {
    unset XDG_CACHE_HOME
    glaipnir_run_no_microvm claude --workspace "$HOME/.ssh"
    assert_success
    assert_run_opt --volume "${HOME}/.cache/glaipnir/workspace:\
/home/aiuser/.cache/glaipnir/workspace:z"
}

@test "workspace dotted outside HOME is accepted" {
    mkdir -p "$BATS_TEST_TMPDIR/.dotted"
    glaipnir_run_no_microvm claude --workspace "$BATS_TEST_TMPDIR/.dotted"
    assert_success
    assert_run_opt_match --volume "/\.dotted:/home/aiuser/"
}

@test "workspace with a ~ inside its name is not rewritten" {
    glaipnir_run_no_microvm claude --workspace "$HOME/odd~dir"
    assert_success
    assert_run_opt_match --volume "^${HOME}/odd~dir:"
}

@test "workspace outside HOME but named after it keeps a sane destination" {
    glaipnir_run_no_microvm claude --workspace "${HOME}-other"
    assert_success
    refute_run_opt_match --volume ':/home/aiuser//'
    assert_run_opt_match --volume ':/home/aiuser/[^/]+:z$'
}
