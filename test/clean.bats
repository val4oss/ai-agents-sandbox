#!/usr/bin/env bats

# Action 'clean': removing containers, images, volumes and build cache.
# Covered: agent containers (-N suffix, microvm suffix), --image, --all,
# build cache cleanup, force removal of running containers, and failure handling.
# The script under test is "$BIN_TEST", see test_helper/common-setup.bash.

setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1
}

# =============================================================================
# Clean agent containers
# =============================================================================

@test "clean <agent> removes only that agent's containers and keeps the image" {
    stub_container "ai-agents-sandbox-claude" running
    stub_container "ai-agents-sandbox-claude-1" running
    stub_container "ai-agents-sandbox-claude-2" exited
    stub_container "ai-agents-sandbox-gemini" running
    stub_container "unrelated-container" running
    stub_image "ai-agents-sandbox-claude" "latest"

    run "$BIN_TEST" clean claude --no-microvm
    assert_success
    assert_output \
        --partial "Stopping and removing container 'ai-agents-sandbox-claude'..."
    assert_output \
        --partial "Stopping and removing container 'ai-agents-sandbox-claude-1'..."
    assert_output \
        --partial "Stopping and removing container 'ai-agents-sandbox-claude-2'..."
    refute_output --partial "ai-agents-sandbox-gemini"
    refute_output --partial "unrelated-container"

    assert_podman_call "rm -f ai-agents-sandbox-claude"
    assert_podman_call "rm -f ai-agents-sandbox-claude-1"
    assert_podman_call "rm -f ai-agents-sandbox-claude-2"
    refute_podman_call "rm -f ai-agents-sandbox-gemini"
    refute_podman_call "rm -f unrelated-container"
    refute_podman_call "image rm"
}

@test "clean <agent> in microVM mode targets -microvm container and suffixes" {
    stub_container "ai-agents-sandbox-claude-microvm" running
    stub_container "ai-agents-sandbox-claude-microvm-1" running
    stub_container "ai-agents-sandbox-claude" running

    run "$BIN_TEST" clean claude
    assert_success
    assert_podman_call "rm -f ai-agents-sandbox-claude-microvm"
    assert_podman_call "rm -f ai-agents-sandbox-claude-microvm-1"
    refute_podman_exact_call "rm -f ai-agents-sandbox-claude"
}

@test "clean removes running containers forcefully" {
    stub_container "ai-agents-sandbox-claude" running

    run "$BIN_TEST" clean claude --no-microvm
    assert_success
    assert_podman_call "rm -f ai-agents-sandbox-claude"
}

@test "clean with no existing containers or images succeeds" {
    run "$BIN_TEST" clean claude --no-microvm
    assert_success
}

# =============================================================================
# Clean with --image
# =============================================================================

@test "clean <agent> --image removes the image and its containers" {
    stub_image "ai-agents-sandbox-claude" "latest" "img1"
    stub_image "ai-agents-sandbox-claude" "1.2.0" "img2"
    stub_image "ai-agents-sandbox-gemini" "latest" "img3"
    stub_container "ai-agents-sandbox-claude" running

    run "$BIN_TEST" clean claude --no-microvm --image
    assert_success
    assert_podman_call "rm -f ai-agents-sandbox-claude"
    assert_podman_call "image rm ai-agents-sandbox-claude:latest"
    assert_podman_call "image rm ai-agents-sandbox-claude:1.2.0"
    refute_podman_call "image rm ai-agents-sandbox-gemini:latest"
    assert_output \
        --partial "All images related to ai-agents-sandbox-claude have been removed."
}

# =============================================================================
# Clean --all
# =============================================================================

@test "clean --all removes all project containers, volumes and images" {
    stub_container "ai-agents-sandbox-claude" running
    stub_container "ai-agents-sandbox-gemini-microvm" running
    stub_container "unrelated-container" running

    stub_volume "ai-agents-sandbox-vol1"
    stub_volume "ai-agents-sandbox-vol2"
    stub_volume "unrelated-volume"

    stub_image "ai-agents-sandbox-claude" "latest" "img1"
    stub_image "ai-agents-sandbox-base" "latest" "img2"
    stub_image "unrelated-image" "latest" "img3"

    run "$BIN_TEST" clean --all
    assert_success

    # Project containers removed, unrelated kept
    assert_podman_call "rm -f ai-agents-sandbox-claude"
    assert_podman_call "rm -f ai-agents-sandbox-gemini-microvm"
    refute_podman_call "rm -f unrelated-container"

    # Project volumes removed, unrelated kept
    assert_podman_call "volume rm -f ai-agents-sandbox-vol1"
    assert_podman_call "volume rm -f ai-agents-sandbox-vol2"
    refute_podman_call "volume rm -f unrelated-volume"

    # Project images removed, unrelated kept
    assert_podman_call "image rm ai-agents-sandbox-claude:latest"
    assert_podman_call "image rm ai-agents-sandbox-base:latest"
    refute_podman_call "image rm unrelated-image:latest"

    assert_output \
        --partial "All images related to ai-agents-sandbox have been removed."
}

# =============================================================================
# Build cache cleanup
# =============================================================================

@test "clean always removes the staging build cache" {
    mkdir -p "$XDG_CACHE_HOME/glaipnir/build/tempdir"
    touch "$XDG_CACHE_HOME/glaipnir/build/tempdir/testfile"
    [ -d "$XDG_CACHE_HOME/glaipnir/build" ]

    run "$BIN_TEST" clean claude --no-microvm
    assert_success
    [ ! -e "$XDG_CACHE_HOME/glaipnir/build" ]
}

@test "clean --all removes the staging build cache" {
    mkdir -p "$XDG_CACHE_HOME/glaipnir/build"
    touch "$XDG_CACHE_HOME/glaipnir/build/file"

    run "$BIN_TEST" clean --all
    assert_success
    [ ! -e "$XDG_CACHE_HOME/glaipnir/build" ]
}

# =============================================================================
# Error reporting
# =============================================================================

@test "clean reports container removal failure and exits 1" {
    stub_container "ai-agents-sandbox-claude" running
    export PODMAN_STUB_FAIL="rm"

    run "$BIN_TEST" clean claude --no-microvm
    assert_failure 1
    assert_output --partial "Failed to remove"
}

@test "clean reports image removal failure and exits 1" {
    stub_image "ai-agents-sandbox-claude" "latest" "img1"
    export PODMAN_STUB_FAIL="image"

    run "$BIN_TEST" clean claude --no-microvm --image
    assert_failure 1
    assert_output --partial "Failed to remove image"
}

@test "clean --all reports volume removal failure and exits 1" {
    stub_volume "ai-agents-sandbox-vol"
    export PODMAN_STUB_FAIL="volume"

    run "$BIN_TEST" clean --all
    assert_failure 1
    assert_output --partial "Failed to remove volume"
}
