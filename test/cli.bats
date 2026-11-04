#!/usr/bin/env bats

# Basic tests of the command line, they do not need podman.
# The script under test is "$BIN_TEST", see test_helper/common-setup.bash.

# Version expected from the script under test (given by 'build.sh test')
VERSION="${VERSION:-1.2.0}"

# Run before each test. The libraries have to be loaded here: a 'load' done in
# setup_file() would not define its functions in the process of the tests.
setup() {
    load 'test_helper/common-setup'
    _common_setup
}

# Test the basic command
@test "testing version ${VERSION}" {
    run "$BIN_TEST" version
    assert_success
    assert_output "${VERSION}"
}
