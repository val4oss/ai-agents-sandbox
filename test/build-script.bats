#!/usr/bin/env bats

# Tests of the 'test' action of build.sh. It is run from a copy of build.sh in
# a temporary root holding two trivial test files, so the real testsuite is
# not run again.

# Run before each test. The libraries have to be loaded here: a 'load' done in
# setup_file() would not define its functions in the process of the tests.
setup() {
    load 'test_helper/common-setup'
    _common_setup
    ROOT_T="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT_T/test"
    cp "$PROJECT_ROOT/build.sh" "$ROOT_T/build.sh"
    ln -s "$PROJECT_ROOT/test/bats" "$ROOT_T/test/bats"
    for _n in one two; do
        printf '#!/usr/bin/env bats\n@test "test of %s" { true; }\n' "$_n" \
            > "$ROOT_T/test/$_n.bats"
    done
    # Any executable does, the fixtures do not use it
    BIN_TEST="$(type -P true)"
    export BIN_TEST
    export NO_COLOR=1
}

@test "build.sh test without name runs all the test files" {
    run sh "$ROOT_T/build.sh" test
    assert_success
    assert_output --partial "test of one"
    assert_output --partial "test of two"
}

@test "build.sh test <name> runs only this test file" {
    run sh "$ROOT_T/build.sh" test one
    assert_success
    assert_output --partial "test of one"
    refute_output --partial "test of two"
}

@test "build.sh test accepts the name with the .bats extension" {
    run sh "$ROOT_T/build.sh" test two.bats
    assert_success
    assert_output --partial "test of two"
    refute_output --partial "test of one"
}

@test "build.sh test accepts several names" {
    run sh "$ROOT_T/build.sh" test two one
    assert_success
    assert_output --partial "test of one"
    assert_output --partial "test of two"
}

@test "build.sh test with an unknown name fails and runs nothing" {
    run sh "$ROOT_T/build.sh" test one missing
    assert_failure 1
    assert_output --partial "Unknown test file: missing"
    assert_output --partial "Action test Failed."
    refute_output --partial "test of one"
}

@test "build.sh test fails when a selected test file fails" {
    printf '#!/usr/bin/env bats\n@test "broken" { false; }\n' \
        > "$ROOT_T/test/bad.bats"
    run sh "$ROOT_T/build.sh" test bad
    assert_failure 1
    assert_output --partial "Tests failed"
}

@test "build.sh help documents the test names" {
    run sh "$ROOT_T/build.sh" help
    assert_success
    assert_output --partial "test [name...]"
}
