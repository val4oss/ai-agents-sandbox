#!/usr/bin/env bats

# Action 'status': reporting images, containers, their states,
# and filtering out unrelated podman objects.
# The script under test is "$BIN_TEST", see test_helper/common-setup.bash.

setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1
}

# =============================================================================
# Status output with empty or populated store
# =============================================================================

@test "status with empty store lists None and exits 0" {
    run "$BIN_TEST" status
    assert_success
    assert_output --partial "Images :"
    assert_output --partial "Containers :"
    assert_output --partial "  None"
}

@test "status lists multiple images matching sandbox prefix" {
    stub_image "ai-agents-sandbox-claude" "latest" "img1"
    stub_image "ai-agents-sandbox-gemini" "1.2.0" "img2"

    run "$BIN_TEST" status
    assert_success
    assert_output --partial "Images :"
    assert_output --partial "  - ai-agents-sandbox-claude:latest"
    assert_output --partial "  - ai-agents-sandbox-gemini:1.2.0"
}

@test "status lists multiple containers and shows their states and images" {
    stub_container "ai-agents-sandbox-claude" "running" "runc" \
        "ai-agents-sandbox-claude:latest"
    stub_container "ai-agents-sandbox-gemini" "exited" "runc" \
        "ai-agents-sandbox-gemini:1.2.0"
    stub_container "ai-agents-sandbox-opencode" "created" "runc" \
        "ai-agents-sandbox-opencode:latest"

    run "$BIN_TEST" status
    assert_success
    assert_output --partial "Containers :"
    assert_output --partial "  - ai-agents-sandbox-claude [running]"
    assert_output --partial "      with ai-agents-sandbox-claude:latest"
    assert_output --partial "  - ai-agents-sandbox-gemini [exited]"
    assert_output --partial "      with ai-agents-sandbox-gemini:1.2.0"
    assert_output --partial "  - ai-agents-sandbox-opencode [created]"
    assert_output --partial "      with ai-agents-sandbox-opencode:latest"
}

# =============================================================================
# Filtering of unrelated podman objects
# =============================================================================

@test "status ignores unrelated images and containers" {
    stub_image "ubuntu" "latest" "u1"
    stub_image "custom-app" "1.0" "c1"
    stub_container "my-database" "running" "runc" "postgres:latest"
    stub_container "other-tool" "exited" "runc" "busybox:latest"

    run "$BIN_TEST" status
    assert_success
    refute_output --partial "ubuntu"
    refute_output --partial "custom-app"
    refute_output --partial "my-database"
    refute_output --partial "other-tool"
    assert_output --partial "Images :
  None"
    assert_output --partial "Containers :
  None"
}

@test "status filters unrelated objects while listing project objects" {
    stub_image "ai-agents-sandbox-claude" "latest" "img1"
    stub_image "unrelated-image" "latest" "u1"

    stub_container "ai-agents-sandbox-claude" "running" "runc" \
        "ai-agents-sandbox-claude:latest"
    stub_container "unrelated-container" "running" "runc" \
        "unrelated-image:latest"

    run "$BIN_TEST" status
    assert_success
    assert_output --partial "  - ai-agents-sandbox-claude:latest"
    refute_output --partial "unrelated-image"
    assert_output --partial "  - ai-agents-sandbox-claude [running]"
    refute_output --partial "unrelated-container"
}

@test "status accepts --all and -a flags and always exits 0" {
    stub_image "ai-agents-sandbox-claude" "latest" "img1"
    stub_container "ai-agents-sandbox-claude" "running" "runc" \
        "ai-agents-sandbox-claude:latest"

    run "$BIN_TEST" status --all
    assert_success
    assert_output --partial "  - ai-agents-sandbox-claude:latest"
    assert_output --partial "  - ai-agents-sandbox-claude [running]"

    run "$BIN_TEST" status -a
    assert_success
    assert_output --partial "  - ai-agents-sandbox-claude:latest"
    assert_output --partial "  - ai-agents-sandbox-claude [running]"
}
