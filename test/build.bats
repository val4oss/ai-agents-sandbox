#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Tests of 'glaipnir build' against a fake podman: nothing is built, the
# arguments given to 'podman build' and the build context are recorded.
# The script under test is "$BIN_TEST", see test_helper/common-setup.bash.

REPO="registry.opensuse.org/home/vlefebvre/container-images/containers/opensuse"

# Run before each test. The libraries have to be loaded here: a 'load' done in
# setup_file() would not define its functions in the process of the tests.
setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1
    BUILD_D="$XDG_CACHE_HOME/glaipnir/build"
}

# Write the configuration file of the test.
# ARGUMENTS:
#   @ - lines of the file
_write_conf() {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    printf '%s\n' "$@" > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
}

# Write a shell script that passes shellcheck.
# ARGUMENTS:
#   1 - path: file to write
_good_hook() {
    printf '#!/bin/sh\necho "hook"\n' > "$1"
}

# Write a shell script that does not pass shellcheck.
# ARGUMENTS:
#   1 - path: file to write
_bad_hook() {
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nrm -rf $UNSET_DIR/*\ncd /tmp\nrm *\n' > "$1"
    printf 'for f in $(ls); do echo $f; done\n' >> "$1"
}

# ===============
# podman build
# ---------------

@test "build calls podman build with the expected options" {
    glaipnir_build claude
    assert_success
    assert_build_arg "--no-cache"
    assert_build_arg "--rm"
    assert_build_arg "--pull=always"
    assert_build_opt --file "$BUILD_D/Containerfile"
    # The build context is the last argument
    [ "$(tail -n 1 "$PODMAN_STUB_BUILD_LOG")" = "$BUILD_D" ]
}

@test "build tags the image with the tag and latest" {
    _write_conf "IMG_TAG=7.8.9"
    glaipnir_build claude
    assert_success
    assert_build_opt --tag "ai-agents-sandbox-claude:7.8.9"
    assert_build_opt --tag "ai-agents-sandbox-claude:latest"
}

_is_arm64() {
    case "$(uname -m)" in
        arm64|aarch64) return 0 ;;
        *)             return 1 ;;
    esac
}

@test "build gives the build args to the Containerfile" {
    _write_conf "IMG_TAG=7.8.9"
    glaipnir_build claude
    assert_success
    if _is_arm64; then
        assert_build_opt --platform "linux/arm64"
        assert_build_opt --build-arg "TARGET_STAGE=from-scratch"
    else
        assert_build_opt --platform "linux/amd64"
        assert_build_opt --build-arg \
            "TARGET_STAGE=$REPO/ai-agents-sandbox-claude:latest"
    fi
    assert_build_opt --build-arg "BUILD_AGENTS=claude"
    assert_build_opt --build-arg "IMG_TAG=7.8.9"
    assert_build_opt_match --build-arg "^PKGS="
    assert_build_opt_match --build-arg "^REPOS="
}

@test "build of a single agent targets the stage of this agent" {
    for _a in claude opencode pi; do
        glaipnir_build "$_a"
        assert_success
        if _is_arm64; then
            assert_build_opt --build-arg "TARGET_STAGE=from-scratch"
        else
            assert_build_opt --build-arg \
                "TARGET_STAGE=$REPO/ai-agents-sandbox-${_a}:latest"
        fi
        assert_build_opt --tag "ai-agents-sandbox-${_a}:latest"
    done
}

@test "build of several agents targets the base stage" {
    glaipnir_build claude pi
    assert_success
    if _is_arm64; then
        assert_build_opt --build-arg "TARGET_STAGE=from-scratch"
    else
        assert_build_opt --build-arg \
            "TARGET_STAGE=$REPO/ai-agents-sandbox-base:latest"
    fi
    assert_build_opt --build-arg "BUILD_AGENTS=claude pi"
    assert_build_opt --tag "ai-agents-sandbox-claude-pi:latest"
}

@test "build --full targets the from-scratch stage" {
    glaipnir_build claude --full
    assert_success
    assert_build_opt --build-arg "TARGET_STAGE=from-scratch"
    glaipnir_build claude pi full
    assert_success
    assert_build_opt --build-arg "TARGET_STAGE=from-scratch"
}

@test "build gives PACKAGES and REPOS of the configuration" {
    _write_conf \
        "PACKAGES=(" "    git" "    vim-small" ")" \
        "REPOS=(" "    https://example.org/repo1" ")"
    glaipnir_build claude
    assert_success
    assert_build_opt_match --build-arg "^PKGS=.*git vim-small"
    assert_build_opt_match --build-arg "^REPOS=.*https://example.org/repo1"
}

@test "build -vv adds the debug log level to podman" {
    glaipnir_build claude -vv
    assert_success
    grep -q -- "^--log-level=debug build " "$PODMAN_STUB_LOG"
}

@test "build without -vv does not add the debug log level" {
    glaipnir_build claude -v
    assert_success
    run ! grep -q -- "--log-level" "$PODMAN_STUB_LOG"
}

@test "build fails when podman build fails" {
    export PODMAN_STUB_BUILD_FAIL=1
    glaipnir_build claude
    assert_failure 1
    assert_output --partial "Image build failed"
}

# ================
# Build context
# ----------------

@test "build context is a copy of image/ removed afterwards" {
    glaipnir_build claude
    assert_success
    # The context recorded by the stub has the files of image/
    grep -qx "./Containerfile" "$PODMAN_STUB_BUILD_CTX"
    grep -qx "./hooks/build" "$PODMAN_STUB_BUILD_CTX"
    [ ! -e "$BUILD_D" ]
}

@test "build context is removed when the build fails" {
    export PODMAN_STUB_BUILD_FAIL=1
    glaipnir_build claude
    assert_failure 1
    [ -s "$PODMAN_STUB_BUILD_CTX" ]
    [ ! -e "$BUILD_D" ]
}

@test "build context drops the content of a previous build" {
    mkdir -p "$BUILD_D"
    touch "$BUILD_D/stale-file"
    glaipnir_build claude
    assert_success
    run ! grep -q "stale-file" "$PODMAN_STUB_BUILD_CTX"
}

@test "build keeps a cache with spaces as one argument" {
    _c="$(realpath "$BATS_TEST_TMPDIR")/home/my cache"
    glaipnir_build claude --cache "$_c"
    assert_success
    assert_build_opt --file "$_c/build/Containerfile"
    [ "$(tail -n 1 "$PODMAN_STUB_BUILD_LOG")" = "$_c/build" ]
}

@test "build does not execute the values of the configuration" {
    _write_conf \
        'PACKAGES=(' '    `touch '"$HOME"'/pwned-pkg`' ')' \
        'REPOS=(' '    `touch '"$HOME"'/pwned-repo`' ')'
    glaipnir_build claude
    assert_success
    [ ! -e "$HOME/pwned-pkg" ]
    [ ! -e "$HOME/pwned-repo" ]
    assert_build_opt_match --build-arg '^PKGS=.*`touch .*pwned-pkg`'
}

# =======
# Hooks
# -------

@test "build copies a hook file in hooks/build" {
    _good_hook "$BATS_TEST_TMPDIR/my-hook.sh"
    glaipnir_build claude --build-hook "$BATS_TEST_TMPDIR/my-hook.sh"
    assert_success
    grep -qx "./hooks/build/my-hook.sh" "$PODMAN_STUB_BUILD_CTX"
}

@test "build copies only the NN-*.sh files of a hook directory" {
    _d="$BATS_TEST_TMPDIR/hooks"
    mkdir -p "$_d"
    _good_hook "$_d/10-first.sh"
    _good_hook "$_d/20-second.sh"
    _good_hook "$_d/no-number.sh"
    _good_hook "$_d/1-short.sh"
    printf 'text\n' > "$_d/30-not-a-script.txt"
    glaipnir_build claude --build-hook "$_d"
    assert_success
    grep -qx "./hooks/build/10-first.sh" "$PODMAN_STUB_BUILD_CTX"
    grep -qx "./hooks/build/20-second.sh" "$PODMAN_STUB_BUILD_CTX"
    run ! grep -q "no-number.sh" "$PODMAN_STUB_BUILD_CTX"
    run ! grep -q "1-short.sh" "$PODMAN_STUB_BUILD_CTX"
    run ! grep -q "30-not-a-script" "$PODMAN_STUB_BUILD_CTX"
}

@test "build with a hook failing shellcheck is aborted" {
    command -v shellcheck >/dev/null || skip "shellcheck is not installed"
    _bad_hook "$BATS_TEST_TMPDIR/bad.sh"
    glaipnir_build claude --build-hook "$BATS_TEST_TMPDIR/bad.sh"
    assert_failure 1
    assert_output --partial "malformated hook script"
    refute_build_called
}

@test "build is aborted when a hook of a directory fails shellcheck" {
    command -v shellcheck >/dev/null || skip "shellcheck is not installed"
    _d="$BATS_TEST_TMPDIR/hooks"
    mkdir -p "$_d"
    # The failing hook comes first, a good one follows
    _bad_hook "$_d/10-bad.sh"
    _good_hook "$_d/20-good.sh"
    glaipnir_build claude --build-hook "$_d"
    assert_failure 1
    refute_build_called
}

@test "build with a non-existing hook is refused" {
    glaipnir_build claude --build-hook "$BATS_TEST_TMPDIR/missing.sh"
    assert_failure 1
    assert_output --partial "not found"
    refute_build_called
}

# =================
# Previous images
# -----------------

@test "build removes the previous images and keeps the new one" {
    _write_conf "IMG_TAG=2.0.0"
    cat > "$BATS_TEST_TMPDIR/images" << 'LIST'
ai-agents-sandbox-claude 1.0.0 aaaaaaaa
localhost/ai-agents-sandbox-claude 1.1.0 bbbbbbbb
ai-agents-sandbox-claude 2.0.0 cccccccc
registry.example.org/ai-agents-sandbox-claude 1.0.0 dddddddd
ai-agents-sandbox-pi 1.0.0 eeeeeeee
LIST
    export PODMAN_STUB_IMAGES="$BATS_TEST_TMPDIR/images"
    glaipnir_build claude
    assert_success
    grep -q "^image rm aaaaaaaa" "$PODMAN_STUB_LOG"
    grep -q "^image rm bbbbbbbb" "$PODMAN_STUB_LOG"
    # the new image, a remote one and another agent are kept
    run ! grep -q "^image rm cccccccc" "$PODMAN_STUB_LOG"
    run ! grep -q "^image rm dddddddd" "$PODMAN_STUB_LOG"
    run ! grep -q "^image rm eeeeeeee" "$PODMAN_STUB_LOG"
}

@test "build keeps the previous images when the build fails" {
    _write_conf "IMG_TAG=2.0.0"
    printf 'ai-agents-sandbox-claude 1.0.0 aaaaaaaa\n' \
        > "$BATS_TEST_TMPDIR/images"
    export PODMAN_STUB_IMAGES="$BATS_TEST_TMPDIR/images"
    export PODMAN_STUB_BUILD_FAIL=1
    glaipnir_build claude
    assert_failure 1
    run ! grep -q "^image rm" "$PODMAN_STUB_LOG"
}
