#!/usr/bin/env bats

# Run once before all the tests of this file: isolate podman and glaipnir state
# into a temporary directory, then build a tiny offline image named like the
# real one.
setup_file() {
    command -v podman >/dev/null 2>&1 || skip "podman is not installed"
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-isolation'
    TEST_D="$(mktemp -d "${GLAIPNIR_TEST_TMPDIR:-${TMPDIR:-/tmp}}/glaipnir.XXXXXX")"
    export TEST_D
    isolate_podman "$TEST_D" || exit 1

    printf 'FROM scratch\nLABEL test=1\n' > "$TEST_D/Containerfile"
    podman build -q -t "ai-agents-sandbox:${VERSION}" \
        -f "$TEST_D/Containerfile" "$TEST_D" >/dev/null || exit 1
}

# Run once after all the tests of this file
teardown_file() {
    [ -n "${TEST_D:-}" ] || return 0
    load 'test_helper/podman-isolation'
    cleanup_podman "$TEST_D"
}

setup() {
    load 'test_helper/common-setup'
    _common_setup
}

@test "podman storage lives in the temporary dir" {
    run podman info --format '{{.Store.GraphRoot}}'
    assert_output "${TEST_D}/graph"
}

@test "status lists the image of the isolated store and no container" {
    run "$BIN_TEST" status
    assert_success
    assert_output --partial "ai-agents-sandbox:${VERSION}"
    assert_output --partial "Containers :"$'\n'"  None"
}

@test "clean --all removes the image from the isolated store" {
    run "$BIN_TEST" clean --all
    assert_success
    run "$BIN_TEST" status
    assert_output --partial "Images :"$'\n'"  None"
}

@test "glaipnir only wrote under the temporary dir" {
    # save-data archives $XDG_CACHE_HOME/glaipnir/agents-mount
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount"
    echo test > "$XDG_CACHE_HOME/glaipnir/agents-mount/file"
    run "$BIN_TEST" save-data
    assert_success
    run find "$TEST_D/data/glaipnir" -name 'glaipnir-data-*.tar.gz'
    assert_output --regexp 'glaipnir-data-.*\.tar\.gz'

    # the real podman store was not modified by the suite
    _now="$(env -u CONTAINERS_STORAGE_CONF -u CONTAINERS_CONF \
        -u XDG_RUNTIME_DIR -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
        -u XDG_DATA_HOME HOME="$REAL_HOME" podman images -q |
        sort -u | tr '\n' ' ')"
    [ "$_now" = "$REAL_IMAGES" ]
}
