#!/usr/bin/env bats

# Real build of the image from image/Containerfile, with a real podman.
# It needs the network and takes minutes, so it is opt-in:
#
#   GLAIPNIR_TEST_REAL_BUILD=1 sh build.sh test
#   GLAIPNIR_TEST_REAL_BUILD=1 BIN_TEST=src/glaipnir.sh \
#       test/bats/bin/bats test/build-real.bats
#
# Set GLAIPNIR_TEST_REAL_BUILD_FULL=1 instead to also build the 'from-scratch'
# stage (the whole system, very long). It implies GLAIPNIR_TEST_REAL_BUILD.
#
# The podman state is isolated in a temporary directory, see
# test_helper/podman-isolation.bash. The script under test is "$BIN_TEST".

TAG="t3-real"

# Run once before all the tests of this file: build the image one time, with a
# build hook, and keep the result for the tests.
setup_file() {
    [ "${GLAIPNIR_TEST_REAL_BUILD:-0}" = 1 ] ||
        [ "${GLAIPNIR_TEST_REAL_BUILD_FULL:-0}" = 1 ] ||
        skip "real build is opt-in: set GLAIPNIR_TEST_REAL_BUILD=1"
    command -v podman >/dev/null 2>&1 || skip "podman is not installed"
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-isolation'
    _tmp_d="${GLAIPNIR_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    TEST_D="$(mktemp -d "${_tmp_d}/glaipnir.XXXXXX")"
    export TEST_D
    # Never reach the real store: on failure, forget the directory so that
    # teardown_file() does not run podman (it removes every container)
    isolate_podman "$TEST_D" || {
        _failed_d="$TEST_D"
        unset TEST_D
        rm -rf "$_failed_d"
        exit 1
    }

    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    printf 'IMG_TAG=%s\n' "$TAG" > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
    printf '#!/bin/sh\ntouch /etc/glaipnir-test-hook\n' > "$TEST_D/10-hook.sh"

    # A failing build must be reported by the tests, not abort the setup
    NO_COLOR=1 "$BIN_TEST" build claude -v --build-hook "$TEST_D/10-hook.sh" \
        > "$TEST_D/build.out" 2>&1
    printf '%s\n' "$?" > "$TEST_D/build.rc"
}

# Run once after all the tests of this file
teardown_file() {
    [ -n "${TEST_D:-}" ] || return 0
    load 'test_helper/podman-isolation'
    cleanup_podman "$TEST_D"
}

# Run before each test
setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-isolation'
    export NO_COLOR=1
}

# Run a command in a container of the built image, without the entrypoint.
# ARGUMENTS:
#   1 - img: image to run
#   @ - command and arguments to run in the container
_in_image() {
    _img="$1"
    shift
    podman run --rm --entrypoint /bin/sh "$_img" -c "$@"
}

@test "podman storage lives in the temporary dir" {
    run podman info --format '{{.Store.GraphRoot}}'
    assert_output "${TEST_D}/graph"
}

@test "the Containerfile builds the image" {
    [ "$(cat "$TEST_D/build.rc")" = 0 ] ||
        fail "build failed:"$'\n'"$(tail -n 50 "$TEST_D/build.out")"
}

@test "the image is tagged with the tag and latest" {
    run podman image exists "ai-agents-sandbox-claude:$TAG"
    assert_success
    run podman image exists "ai-agents-sandbox-claude:latest"
    assert_success
}

@test "the image has the version label" {
    run podman image inspect "ai-agents-sandbox-claude:$TAG" \
        --format '{{index .Config.Labels "version"}}'
    assert_success
    assert_output "$TAG"
}

@test "the image runs as the unprivileged user" {
    run _in_image "ai-agents-sandbox-claude:$TAG" 'id -un; id -u'
    assert_success
    assert_line --index 0 "aiuser"
    assert_line --index 1 "1000"
}

@test "the selected agent is installed, the other ones are not" {
    run _in_image "ai-agents-sandbox-claude:$TAG" 'command -v claude'
    assert_success
    run _in_image "ai-agents-sandbox-claude:$TAG" \
        'command -v gemini || command -v opencode || command -v pi'
    assert_failure
}

@test "the base tools of the published base image are installed" {
    run _in_image "ai-agents-sandbox-claude:$TAG" \
        'command -v git && command -v shellcheck'
    assert_success
}

@test "the build hook ran during the build" {
    run _in_image "ai-agents-sandbox-claude:$TAG" \
        'test -f /etc/glaipnir-test-hook'
    assert_success
}

@test "the build context is removed after the build" {
    [ ! -e "$XDG_CACHE_HOME/glaipnir/build" ]
}

@test "status lists the built image" {
    run "$BIN_TEST" status
    assert_success
    assert_output --partial "ai-agents-sandbox-claude:$TAG"
}

@test "the from-scratch stage builds" {
    [ "${GLAIPNIR_TEST_REAL_BUILD_FULL:-0}" = 1 ] ||
        skip "set GLAIPNIR_TEST_REAL_BUILD_FULL=1 to build from scratch"
    printf 'IMG_TAG=%s-full\n' "$TAG" \
        > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
    run "$BIN_TEST" build pi --full -v
    assert_success
    run _in_image "ai-agents-sandbox-pi:${TAG}-full" 'command -v pi'
    assert_success
    # The packages of the Containerfile itself, not of the published base
    run _in_image "ai-agents-sandbox-pi:${TAG}-full" \
        'command -v git && command -v shellcheck && command -v socat'
    assert_success
}

# Keep it the last test: it checks everything done by the previous ones
@test "the real podman store is not modified" {
    [ "$(real_podman images -q | sort -u | tr '\n' ' ')" = "$REAL_IMAGES" ]
    [ "$(real_podman ps -a -q | sort -u | tr '\n' ' ')" = \
        "$REAL_CONTAINERS" ]
    [ "$(real_podman volume ls -q | sort -u | tr '\n' ' ')" = \
        "$REAL_VOLUMES" ]
}
