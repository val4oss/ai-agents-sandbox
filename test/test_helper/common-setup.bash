#!/usr/bin/env bash

# BIN_TEST and PRINTER are read by the test files, not by this helper.
# shellcheck disable=SC2034
_common_setup() {
    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'

    # get the containing directory of this file. Use $BATS_TEST_FILENAME
    # instead of ${BASH_SOURCE[0]} or $0, as those point to the location of
    # the bats executable and to the preprocessed file respectively.
    PROJECT_ROOT="$(
        cd "$( dirname "$BATS_TEST_FILENAME" )/.." >/dev/null 2>&1 && pwd
    )"

    # Script under test, the sources by default. 'build.sh test' gives the
    # built one. It has to be absolute: some tests change the directory.
    BIN_TEST="$(realpath "${BIN_TEST:-${PROJECT_ROOT}/src/glaipnir.sh}")"

    # make the command under test visible to PATH
    PATH="$( dirname "$BIN_TEST" ):$PATH"
}
