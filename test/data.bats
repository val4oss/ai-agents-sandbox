#!/usr/bin/env bats

# Action 'clean-cache', 'clean-data', 'save-data', 'restore-data':
# Cache directory cleanup, data directory cleanup, archiving and restoring
# agent configuration, migration of legacy cache dir, and security checks.
# The script under test is "$BIN_TEST", see test_helper/common-setup.bash.

setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1
}

# =============================================================================
# clean-cache
# =============================================================================

@test "clean-cache removes CACHE_D and only it" {
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount"
    mkdir -p "$XDG_CACHE_HOME/other-app"
    touch "$XDG_CACHE_HOME/glaipnir/agents-mount/file"
    touch "$XDG_CACHE_HOME/other-app/file"

    run "$BIN_TEST" clean-cache
    assert_success
    assert_output --partial "podman volumes and Cache has been cleaned."
    [ ! -e "$XDG_CACHE_HOME/glaipnir" ]
    [ -d "$XDG_CACHE_HOME/other-app" ]
}

@test "clean-cache succeeds even when CACHE_D is absent" {
    rm -rf "$XDG_CACHE_HOME/glaipnir"
    run "$BIN_TEST" clean-cache
    assert_success
}

# =============================================================================
# clean-data
# =============================================================================

@test "clean-data removes HOME_DATA_D" {
    mkdir -p "$XDG_DATA_HOME/glaipnir"
    mkdir -p "$XDG_DATA_HOME/other-data"
    touch "$XDG_DATA_HOME/glaipnir/test.tar.gz"
    touch "$XDG_DATA_HOME/other-data/file"

    run "$BIN_TEST" clean-data
    assert_success
    assert_output --partial "Data directory has been cleaned."
    [ ! -e "$XDG_DATA_HOME/glaipnir" ]
    [ -d "$XDG_DATA_HOME/other-data" ]
}

@test "clean-data succeeds even when HOME_DATA_D is absent" {
    rm -rf "$XDG_DATA_HOME/glaipnir"
    run "$BIN_TEST" clean-data
    assert_success
}

# =============================================================================
# save-data
# =============================================================================

@test "save-data fails when agents-mount is missing" {
    rm -rf "$XDG_CACHE_HOME/glaipnir/agents-mount"
    run "$BIN_TEST" save-data
    assert_failure 1
    assert_output --partial "No agents configuration found"
}

@test "save-data creates data directory and archives relative agents-mount" {
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount/claude"
    echo "testconfig" > "$XDG_CACHE_HOME/glaipnir/agents-mount/claude/config.json"
    rm -rf "$XDG_DATA_HOME/glaipnir"

    run "$BIN_TEST" save-data
    assert_success
    [ -d "$XDG_DATA_HOME/glaipnir" ]

    # Check archive name format: glaipnir-data-YYYYmmdd_HHMMSS.tar.gz
    _arc="$(find "$XDG_DATA_HOME/glaipnir" -name 'glaipnir-data-*.tar.gz')"
    [ -n "$_arc" ]
    [[ "$_arc" =~ glaipnir-data-[0-9]{8}_[0-9]{6}\.tar\.gz$ ]]

    # Check archive content is relative (agents-mount/...)
    _contents="$(tar -tf "$_arc")"
    [[ "$_contents" == *"agents-mount/"* ]]
    refute_output --partial "/"$_arc
    [[ "$_contents" != /* ]]
}

@test "two saves in the same second do not overwrite each other" {
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount"
    echo "version1" > "$XDG_CACHE_HOME/glaipnir/agents-mount/file"

    run "$BIN_TEST" save-data
    assert_success

    echo "version2" > "$XDG_CACHE_HOME/glaipnir/agents-mount/file"
    run "$BIN_TEST" save-data
    assert_failure 1
    assert_output --partial "already exists"

    # Only 1 archive was created; the first archive was preserved
    _count="$(find "$XDG_DATA_HOME/glaipnir" \
        -name 'glaipnir-data-*.tar.gz' | wc -l)"
    [ "$_count" -eq 1 ]
}

# =============================================================================
# restore-data
# =============================================================================

@test "restore-data fails when data directory does not exist" {
    rm -rf "$XDG_DATA_HOME/glaipnir"
    run "$BIN_TEST" restore-data
    assert_failure 1
    assert_output --partial "Data directory"
    assert_output --partial "does not exist."
}

@test "restore-data fails when no archive is found in data directory" {
    mkdir -p "$XDG_DATA_HOME/glaipnir"
    rm -f "$XDG_DATA_HOME/glaipnir/"*.tar.gz
    run "$BIN_TEST" restore-data
    assert_failure 1
    assert_output --partial "No saved data archive found"
}

@test "restore-data picks the latest archive" {
    mkdir -p "$XDG_DATA_HOME/glaipnir"
    mkdir -p "$BATS_TEST_TMPDIR/temp_cache/agents-mount"

    echo "archive1" > "$BATS_TEST_TMPDIR/temp_cache/agents-mount/data"
    tar -czf "$XDG_DATA_HOME/glaipnir/glaipnir-data-20260101_000001.tar.gz" \
        -C "$BATS_TEST_TMPDIR/temp_cache" "agents-mount"

    echo "archive2" > "$BATS_TEST_TMPDIR/temp_cache/agents-mount/data"
    tar -czf "$XDG_DATA_HOME/glaipnir/glaipnir-data-20260102_000002.tar.gz" \
        -C "$BATS_TEST_TMPDIR/temp_cache" "agents-mount"

    rm -rf "$XDG_CACHE_HOME/glaipnir"

    run "$BIN_TEST" restore-data
    assert_success
    assert_output --partial "glaipnir-data-20260102_000002.tar.gz"
    [ -f "$XDG_CACHE_HOME/glaipnir/agents-mount/data" ]
    [ "$(cat "$XDG_CACHE_HOME/glaipnir/agents-mount/data")" = "archive2" ]
}

@test "restore-data refuses when agents-mount exists unless --force" {
    mkdir -p "$XDG_DATA_HOME/glaipnir"
    mkdir -p "$BATS_TEST_TMPDIR/temp_cache/agents-mount"
    echo "archived" > "$BATS_TEST_TMPDIR/temp_cache/agents-mount/data"
    tar -czf "$XDG_DATA_HOME/glaipnir/glaipnir-data-20260101_000001.tar.gz" \
        -C "$BATS_TEST_TMPDIR/temp_cache" "agents-mount"

    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount"
    echo "current" > "$XDG_CACHE_HOME/glaipnir/agents-mount/data"

    # Without --force: warns and does not overwrite
    run "$BIN_TEST" restore-data
    assert_success
    assert_output --partial "Cache data already exists"
    assert_output --partial "Avoided restoring. Use '--force' to override."
    [ "$(cat "$XDG_CACHE_HOME/glaipnir/agents-mount/data")" = "current" ]

    # With --force: overwrites
    run "$BIN_TEST" restore-data --force
    assert_success
    assert_output --partial "Force flag set: removing existing"
    [ "$(cat "$XDG_CACHE_HOME/glaipnir/agents-mount/data")" = "archived" ]
}

@test "restore-data creates CACHE_D when missing" {
    mkdir -p "$XDG_DATA_HOME/glaipnir"
    mkdir -p "$BATS_TEST_TMPDIR/temp_cache/agents-mount"
    echo "restored" > "$BATS_TEST_TMPDIR/temp_cache/agents-mount/file"
    tar -czf "$XDG_DATA_HOME/glaipnir/glaipnir-data-20260101_000001.tar.gz" \
        -C "$BATS_TEST_TMPDIR/temp_cache" "agents-mount"

    rm -rf "$XDG_CACHE_HOME/glaipnir"

    run "$BIN_TEST" restore-data
    assert_success
    [ -d "$XDG_CACHE_HOME/glaipnir/agents-mount" ]
    [ -f "$XDG_CACHE_HOME/glaipnir/agents-mount/file" ]
}

@test "restore of archive with traversal does not write outside CACHE_D" {
    mkdir -p "$XDG_DATA_HOME/glaipnir"
    canary="$BATS_TEST_TMPDIR/canary_file"
    rm -f "$canary"

    # Create an archive with path traversal
    python3 -c "
import tarfile, io
with tarfile.open('$XDG_DATA_HOME/glaipnir/glaipnir-data-20260101_000001.tar.gz', 'w:gz') as tar:
    data = b'evil'
    ti = tarfile.TarInfo(name='../canary_file')
    ti.size = len(data)
    tar.addfile(ti, io.BytesIO(data))
"
    rm -rf "$XDG_CACHE_HOME/glaipnir"

    run "$BIN_TEST" restore-data
    [ ! -e "$canary" ]
}

# =============================================================================
# Round trip and legacy migration
# =============================================================================

@test "save-data, clean-cache, and restore-data round trip preserves tree" {
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount/agent1/subdir"
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount/agent2"
    echo "secret1" > "$XDG_CACHE_HOME/glaipnir/agents-mount/agent1/token"
    echo "secret2" > "$XDG_CACHE_HOME/glaipnir/agents-mount/agent1/subdir/nested"
    echo "secret3" > "$XDG_CACHE_HOME/glaipnir/agents-mount/agent2/conf"

    run "$BIN_TEST" save-data
    assert_success

    run "$BIN_TEST" clean-cache
    assert_success
    [ ! -e "$XDG_CACHE_HOME/glaipnir" ]

    run "$BIN_TEST" restore-data
    assert_success

    [ "$(cat "$XDG_CACHE_HOME/glaipnir/agents-mount/agent1/token")" = "secret1" ]
    [ "$(cat "$XDG_CACHE_HOME/glaipnir/agents-mount/agent1/subdir/nested")" = "secret2" ]
    [ "$(cat "$XDG_CACHE_HOME/glaipnir/agents-mount/agent2/conf")" = "secret3" ]
}

@test "migration moves legacy ~/.cache/ai-agents-sandbox to ~/.cache/glaipnir" {
    rm -rf "$XDG_CACHE_HOME/glaipnir"
    mkdir -p "$HOME/.cache/ai-agents-sandbox/agents-mount"
    echo "migrated" > "$HOME/.cache/ai-agents-sandbox/agents-mount/legacy_data"

    # Any command initializing cache triggers migration
    run "$BIN_TEST" status
    assert_success

    [ ! -e "$HOME/.cache/ai-agents-sandbox" ]
    [ -d "$XDG_CACHE_HOME/glaipnir/agents-mount" ]
    [ -f "$XDG_CACHE_HOME/glaipnir/agents-mount/legacy_data" ]
    [ "$(cat "$XDG_CACHE_HOME/glaipnir/agents-mount/legacy_data")" = "migrated" ]
}

@test "migration does not overwrite existing ~/.cache/glaipnir" {
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount"
    echo "new" > "$XDG_CACHE_HOME/glaipnir/agents-mount/data"

    mkdir -p "$HOME/.cache/ai-agents-sandbox/agents-mount"
    echo "old" > "$HOME/.cache/ai-agents-sandbox/agents-mount/data"

    run "$BIN_TEST" status
    assert_success

    # Both directories preserved, new is untouched
    [ -d "$HOME/.cache/ai-agents-sandbox" ]
    [ "$(cat "$XDG_CACHE_HOME/glaipnir/agents-mount/data")" = "new" ]
}
