#!/usr/bin/env bats

# Basic tests of the command line, they do not need podman.
# The script under test is "$BIN_TEST", see test_helper/common-setup.bash.

# Run before each test. The libraries have to be loaded here: a 'load' done in
# setup_file() would not define its functions in the process of the tests.
setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1
}

# ====================
# Help, Version, Usage
# --------------------

@test "no argument prints missing command error, usage, and exits 1" {
    run "$BIN_TEST"
    assert_failure 1
    assert_output --partial "Missing command"
    assert_output --partial "Usage:"
}

@test "help, --help, and -h exit 0 and print usage" {
    for _h in help --help -h; do
        run "$BIN_TEST" "$_h"
        assert_success
        assert_output --partial "Usage:"
    done
}

@test "version and --version print the version" {
    for _v in version --version; do
        run "$BIN_TEST" "$_v"
        assert_success
        assert_output "${VERSION}"
    done
}

@test "unknown option prints error, usage, and exits 1" {
    run "$BIN_TEST" --unknown-option
    assert_failure 1
    assert_output --partial "Unknown option: --unknown-option"
    assert_output --partial "Usage:"
}

@test "no action prints warning and usage" {
    run "$BIN_TEST" claude
    assert_success
    assert_output --partial "No action specified. Nothing to do."
    assert_output --partial "Usage:"
}

# ==========
# Verbosity
# ----------

@test "-q and --quiet suppress info and warning messages" {
    run "$BIN_TEST" -q run claude --no-microvm --workspace "$WS"
    assert_success
    refute_output --partial "[INFO]"
    refute_output --partial "[WARN]"

    run "$BIN_TEST" --quiet run claude --no-microvm --workspace "$WS"
    assert_success
    refute_output --partial "[INFO]"
    refute_output --partial "[WARN]"
}

@test "-v and -vv change verbosity and pass debug options" {
    run "$BIN_TEST" -v run claude --no-microvm --workspace "$WS"
    assert_success
    assert_output --partial "[DEBG]"

    run "$BIN_TEST" -vv run claude --no-microvm --workspace "$WS"
    assert_success
    assert_output --partial "[DEBG]"
    grep -q -- "--log-level=debug" "$PODMAN_STUB_LOG"
}

# ========================
# Action Callbacks Mapping
# ------------------------

@test "clean-cache removes cache directory" {
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount"
    run "$BIN_TEST" clean-cache
    assert_success
    assert_output --partial "Removing cache dir"
    [ ! -d "$XDG_CACHE_HOME/glaipnir" ]
}

@test "clean-data removes data directory" {
    mkdir -p "$XDG_DATA_HOME/glaipnir"
    touch "$XDG_DATA_HOME/glaipnir/dummy"
    run "$BIN_TEST" clean-data
    assert_success
    assert_output --partial "Removing data dir"
    [ ! -e "$XDG_DATA_HOME/glaipnir/dummy" ]
}

@test "save-data and restore-data map to their functions" {
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount"
    echo "testdata" > "$XDG_CACHE_HOME/glaipnir/agents-mount/sample.txt"
    run "$BIN_TEST" save-data
    assert_success
    assert_output --partial "Data archive successfully saved"

    rm -rf "$XDG_CACHE_HOME/glaipnir/agents-mount"
    run "$BIN_TEST" restore-data --force
    assert_success
    assert_output --partial "Data successfully restored"
    [ -f "$XDG_CACHE_HOME/glaipnir/agents-mount/sample.txt" ]
}

# ==========================
# CLI Flags and Accumulation
# --------------------------

@test "--no-microvm and --no-vpn-protection flags take effect" {
    run "$BIN_TEST" run claude --workspace "$WS" --no-microvm --no-vpn-protection
    assert_success
    assert_run_opt "--network" "pasta"
}

@test "multiple --dns flags accumulate" {
    run "$BIN_TEST" run claude --workspace "$WS" --no-microvm --dns 1.1.1.1 --dns 8.8.8.8 --dns 9.9.9.9
    assert_success
    assert_run_opt "--dns" "1.1.1.1"
    assert_run_opt "--dns" "8.8.8.8"
    assert_run_opt "--dns" "9.9.9.9"
}

@test "--full flag sets from-scratch stage on build" {
    run "$BIN_TEST" build claude --full
    assert_success
    grep -q "TARGET_STAGE=from-scratch" "$PODMAN_STUB_LOG"
}

@test "--all, -a, and --force flags take effect" {
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount"
    echo "orig" > "$XDG_CACHE_HOME/glaipnir/agents-mount/orig.txt"
    run "$BIN_TEST" save-data
    assert_success

    # Without --force, restore-data avoids restoring when cache exists
    run "$BIN_TEST" restore-data
    assert_success
    assert_output --partial "Avoided restoring. Use '--force' to override."

    # With --force, restore-data overrides existing cache
    run "$BIN_TEST" restore-data --force
    assert_success
    assert_output --partial "Data successfully restored"
}

@test "--reset-agent-config flag removes existing agents-mount" {
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount"
    touch "$XDG_CACHE_HOME/glaipnir/agents-mount/old.txt"
    run "$BIN_TEST" run claude --workspace "$WS" --no-microvm --reset-agent-config
    assert_success
    assert_output --partial "Removing the agents configuration"
}

@test "--image flag is set only with clean action" {
    # clean without --image does not remove images
    run "$BIN_TEST" clean claude
    assert_success
    refute_output --partial "All images related to"

    # clean with --image removes images
    run "$BIN_TEST" clean claude --image
    assert_success
    assert_output --partial "All images related to ai-agents-sandbox-claude have been removed."

    # --image with run action has no effect on images
    run "$BIN_TEST" run claude --workspace "$WS" --no-microvm --image
    assert_success
    refute_output --partial "All images related to"
}

@test "--cache and --data-dir take effect from CLI" {
    mkdir -p "$BATS_TEST_TMPDIR/custom_cache" "$BATS_TEST_TMPDIR/custom_data"
    mkdir -p "$BATS_TEST_TMPDIR/custom_cache/agents-mount"
    echo "saved" > "$BATS_TEST_TMPDIR/custom_cache/agents-mount/saved.txt"

    run "$BIN_TEST" save-data --cache "$BATS_TEST_TMPDIR/custom_cache" --data-dir "$BATS_TEST_TMPDIR/custom_data"
    assert_success
    run find "$BATS_TEST_TMPDIR/custom_data" -name 'glaipnir-data-*.tar.gz'
    assert_output --regexp 'glaipnir-data-.*\.tar\.gz'
}

# ===================
# Tools Verification
# -------------------

@test "required tools missing produces error listing them and exits 1" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    for cmd in sh bash cat rm mkdir touch dirname basename realpath sed; do
        p="$(command -v "$cmd" 2>/dev/null || true)"
        [ -n "$p" ] && ln -s "$p" "$BATS_TEST_TMPDIR/bin/$cmd"
    done

    PATH="$BATS_TEST_TMPDIR/bin" run "$BIN_TEST" status
    assert_failure 1
    assert_output --partial "Some tools are missing on your system:"
    assert_output --partial "podman"
    assert_output --partial "Please install the missing tools and try again. Aborting."
}

@test "socat and proxy command binary are required when --cmd is used" {
    # If proxy command binary is not on PATH
    run "$BIN_TEST" run claude --workspace "$WS" --no-microvm --cmd "nonexistentcmd"
    assert_failure 1
    assert_output --partial "Some tools are missing on your system:"
    assert_output --partial "nonexistentcmd"

    # If socat is not on PATH
    mkdir -p "$BATS_TEST_TMPDIR/bin_no_socat"
    IFS=:
    for dir in $PATH; do
        for f in "$dir"/*; do
            [ -x "$f" ] || continue
            bn="${f##*/}"
            [ "$bn" = "socat" ] && continue
            [ -e "$BATS_TEST_TMPDIR/bin_no_socat/$bn" ] && continue
            ln -s "$f" "$BATS_TEST_TMPDIR/bin_no_socat/$bn" 2>/dev/null || true
        done
    done
    unset IFS
    touch "$BATS_TEST_TMPDIR/bin_no_socat/mycustomcmd"
    chmod +x "$BATS_TEST_TMPDIR/bin_no_socat/mycustomcmd"

    # Run with mycustomcmd available but socat missing
    PATH="$BATS_TEST_TMPDIR/bin_no_socat" run "$BIN_TEST" run claude --workspace "$WS" --no-microvm --cmd "mycustomcmd"
    assert_failure 1
    assert_output --partial "Some tools are missing on your system: socat"
}
