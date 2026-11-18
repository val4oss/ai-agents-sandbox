#!/usr/bin/env bats

# Read-only mounts of host directories: --ro-mount <src>[:<dst>] and RO_MOUNTS
# in the configuration file.
# podman is a stub (test/test_helper/stubs): nothing is started.

setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    mkdir -p "$HOME/docs" "$HOME/other" "$HOME/a/docs"
    REAL_HOME_TEST="$(realpath "$HOME")"
}

# Fail unless 'podman run' was not even called.
_assert_not_started() {
    [ ! -e "$PODMAN_STUB_RUN_LOG" ] || fail "podman run was called"
}

# Write the configuration file glaipnir reads by default.
# ARGUMENTS:
#   stdin - content of the file
_write_conf() {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    cat > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
}

# ============
# Destination
# ------------

@test "ro-mount source alone is mounted in the home of the sandbox" {
    glaipnir_run_no_microvm claude --ro-mount "$HOME/docs"
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/docs:/home/aiuser/docs:ro,z"
}

@test "ro-mount source:dst is mounted on dst" {
    glaipnir_run_no_microvm claude --ro-mount "$HOME/docs:/data"
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/docs:/data:ro,z"
}

@test "ro-mount trailing :ro of the destination is ignored" {
    glaipnir_run_no_microvm claude --ro-mount "$HOME/docs:/data:ro"
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/docs:/data:ro,z"
}

@test "ro-mount destination duplicate and trailing slashes are removed" {
    glaipnir_run_no_microvm claude --ro-mount "$HOME/docs://data//sub/"
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/docs:/data/sub:ro,z"
}

@test "ro-mount destination is not resolved on the host" {
    # a relative destination would be resolved from the current directory
    cd "$HOME"
    glaipnir_run_no_microvm claude --ro-mount "$HOME/docs:relative"
    assert_failure 1
    _assert_not_started
}

@test "ro-mount destination with . or .. parts is refused" {
    for _bad in /home/aiuser/../tmp /data/./sub /.. /data/.; do
        glaipnir_run_no_microvm claude --ro-mount "$HOME/docs:$_bad"
        assert_failure 1
        _assert_not_started
    done
}

@test "ro-mount on the root of the sandbox is refused" {
    glaipnir_run_no_microvm claude --ro-mount "$HOME/docs:/"
    assert_failure 1
    _assert_not_started
}

# ======
# Source
# ------

@test "ro-mount relative source is canonicalised" {
    cd "$HOME"
    glaipnir_run_no_microvm claude --ro-mount docs/../other
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/other:/home/aiuser/other:ro,z"
}

@test "ro-mount source ~ and HOME variables are expanded" {
    glaipnir_run_no_microvm claude \
        --ro-mount '~/docs:/d1' \
        --ro-mount '$HOME/other:/d2' \
        --ro-mount '${HOME}/a:/d3'
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/docs:/d1:ro,z"
    assert_run_opt --volume "${REAL_HOME_TEST}/other:/d2:ro,z"
    assert_run_opt --volume "${REAL_HOME_TEST}/a:/d3:ro,z"
}

@test "ro-mount source outside the allowed paths is refused" {
    _real_etc="$(realpath /etc)"
    glaipnir_run_no_microvm claude --ro-mount /etc
    assert_failure 1
    assert_output --partial "ro mount source '${_real_etc}' is not a valid directory"
    _assert_not_started
}

@test "ro-mount refused source fails the run even next to a valid one" {
    glaipnir_run_no_microvm claude --ro-mount /etc --ro-mount "$HOME/docs"
    assert_failure 1
    _assert_not_started
}

@test "ro-mount source that does not exist is refused and not created" {
    glaipnir_run_no_microvm claude --ro-mount "$HOME/typo"
    assert_failure 1
    [ ! -e "$HOME/typo" ]
    _assert_not_started
}

@test "ro-mount source that is a file is refused" {
    touch "$HOME/afile"
    glaipnir_run_no_microvm claude --ro-mount "$HOME/afile"
    assert_failure 1
    _assert_not_started
}

@test "ro-mount source in a hidden directory of HOME is refused" {
    mkdir -p "$HOME/.ssh"
    glaipnir_run_no_microvm claude --ro-mount "$HOME/.ssh"
    assert_failure 1
    assert_output --partial "forbidden (hidden)"
    _assert_not_started
}

@test "ro-mount source symlinked to a forbidden path is refused" {
    ln -s /etc "$HOME/link"
    glaipnir_run_no_microvm claude --ro-mount "$HOME/link"
    assert_failure 1
    _assert_not_started
}

@test "ro-mount source HOME itself is refused" {
    glaipnir_run_no_microvm claude --ro-mount "$HOME"
    assert_failure 1
    _assert_not_started
}

# ==========
# Collisions
# ----------

@test "ro-mounts with the same default destination collide" {
    glaipnir_run_no_microvm claude \
        --ro-mount "$HOME/docs" --ro-mount "$HOME/a/docs"
    assert_failure 1
    assert_output --partial \
        "ro mounts collide on destination '/home/aiuser/docs'"
    _assert_not_started
}

@test "ro-mounts with the same explicit destination collide" {
    glaipnir_run_no_microvm claude \
        --ro-mount "$HOME/docs:/data" --ro-mount "$HOME/other:/data/"
    assert_failure 1
    _assert_not_started
}

@test "ro-mounts with distinct destinations do not collide" {
    glaipnir_run_no_microvm claude \
        --ro-mount "$HOME/docs" --ro-mount "$HOME/a/docs:/home/aiuser/a-docs"
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/docs:/home/aiuser/docs:ro,z"
    assert_run_opt --volume "${REAL_HOME_TEST}/a/docs:/home/aiuser/a-docs:ro,z"
}

@test "ro-mount on the home or on /tmp of the sandbox is refused" {
    for _bad in /home/aiuser /home/aiuser/ //home//aiuser /tmp /tmp/ //tmp; do
        glaipnir_run_no_microvm claude --ro-mount "$HOME/docs:$_bad"
        assert_failure 1
        assert_output --partial "ro mounts collide on destination"
        _assert_not_started
    done
}

@test "ro-mount source with spaces is mounted" {
    mkdir -p "$HOME/my docs"
    glaipnir_run_no_microvm claude --ro-mount "$HOME/my docs"
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/my docs:/home/aiuser/my docs:ro,z"
}

@test "ro-mount source and destination with spaces and options" {
    mkdir -p "$HOME/my docs"
    glaipnir_run_no_microvm claude --ro-mount "$HOME/my docs:/my data:ro"
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/my docs:/my data:ro,z"
}

@test "ro-mount source with a quote is mounted" {
    mkdir -p "$HOME/it's"
    glaipnir_run_no_microvm claude --ro-mount "$HOME/it's"
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/it's:/home/aiuser/it's:ro,z"
}

@test "ro-mount source with a colon is refused" {
    mkdir -p "$HOME/a:b"
    for _bad in "$HOME/a:b" "$HOME/a:b:/data" "$HOME/docs:relative"; do
        glaipnir_run_no_microvm claude --ro-mount "$_bad"
        assert_failure 1
        assert_output --partial "has a ':' in a path"
        _assert_not_started
    done
}

@test "ro-mount with a | is refused" {
    glaipnir_run_no_microvm claude --ro-mount "$HOME/docs|$HOME/other"
    assert_failure 1
    assert_output --partial "'|' is not allowed"
    _assert_not_started
}

# =============================
# Collisions with other mounts
# -----------------------------

@test "ro-mount on the destination of the workspace is refused" {
    mkdir -p "$HOME/a/ws"
    glaipnir_run_no_microvm claude --ro-mount "$HOME/a/ws"
    assert_failure 1
    assert_output --partial "Two mounts use the destination '/home/aiuser/ws'"
    _assert_not_started
}

@test "ro-mount on the destination of an agent mount is refused" {
    for _bad in /home/aiuser/.claude /home/aiuser/.claude.json \
        /home/aiuser/.agents; do
        glaipnir_run_no_microvm claude --ro-mount "$HOME/docs:$_bad"
        assert_failure 1
        assert_output --partial "Two mounts use the destination '$_bad'"
        _assert_not_started
    done
}

@test "ro-mount on the destination of the run hooks is refused" {
    glaipnir_run_no_microvm claude \
        --ro-mount "$HOME/docs:/usr/local/bin/ai-agents-sandbox-run-hooks"
    assert_failure 1
    assert_output --partial "Two mounts use the destination"
    _assert_not_started
}

@test "ro-mount on the tmpfs of opencode is refused" {
    glaipnir_run_no_microvm opencode --ro-mount "$HOME/docs:/run/agent-tmp"
    assert_failure 1
    assert_output --partial "Two mounts use the destination '/run/agent-tmp'"
    _assert_not_started
}

@test "ro-mount inside the destination of another mount is accepted" {
    _dst=/home/aiuser/.claude/x
    glaipnir_run_no_microvm claude --ro-mount "$HOME/docs:$_dst"
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/docs:${_dst}:ro,z"
}

# ========
# Settings
# --------

@test "several --ro-mount accumulate" {
    glaipnir_run_no_microvm claude \
        --ro-mount "$HOME/docs" --ro-mount "$HOME/other" \
        --ro-mount "$HOME/a:/a"
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/docs:/home/aiuser/docs:ro,z"
    assert_run_opt --volume "${REAL_HOME_TEST}/other:/home/aiuser/other:ro,z"
    assert_run_opt --volume "${REAL_HOME_TEST}/a:/a:ro,z"
}

@test "RO_MOUNTS of the configuration and --ro-mount accumulate" {
    _write_conf <<'EOF'
RO_MOUNTS=(
    ${HOME}/docs:/conf-docs:ro
    ~/a
)
EOF
    glaipnir_run_no_microvm claude --ro-mount "$HOME/other"
    assert_success
    assert_run_opt --volume "${REAL_HOME_TEST}/docs:/conf-docs:ro,z"
    assert_run_opt --volume "${REAL_HOME_TEST}/a:/home/aiuser/a:ro,z"
    assert_run_opt --volume "${REAL_HOME_TEST}/other:/home/aiuser/other:ro,z"
}

# ========
# Read only
# ---------

@test "a ro-mount is never emitted read-write" {
    glaipnir_run_no_microvm claude \
        --ro-mount "$HOME/docs:/d1:rw" --ro-mount "$HOME/other:/d2:z" \
        --ro-mount "$HOME/a:/d3:rw,z"
    assert_success
    _vols="$(run_opt_values --volume | grep -E "^${REAL_HOME_TEST}/(docs|other|a):" || true)"
    [ "$(printf '%s\n' "$_vols" | grep -c .)" -eq 3 ]
    _bad="$(printf '%s\n' "$_vols" | grep -v ':ro,z$' || true)"
    [ -z "$_bad" ] || fail "mount not read-only:"$'\n'"$_bad"
}

@test "no read-only mount without --ro-mount" {
    glaipnir_run_no_microvm claude
    assert_success
    refute_run_opt_match --volume ':ro(,|$)'
}
