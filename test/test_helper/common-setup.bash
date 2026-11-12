#!/usr/bin/env bash

# Resolve default VERSION if not already in the environment
if [ -z "${VERSION:-}" ]; then
    if [ -n "${BIN_TEST:-}" ] && [ -x "${BIN_TEST}" ]; then
        VERSION="$("${BIN_TEST}" version 2>/dev/null || true)"
    fi
    if [ -z "${VERSION:-}" ]; then
        _cs_root="$(
            cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd
        )"
        if [ -f "${_cs_root}/src/glaipnir.sh" ]; then
            VERSION="$(sed -n 's/^IMG_TAG="\([^"]*\)"/\1/p' \
                "${_cs_root}/src/glaipnir.sh" 2>/dev/null || true)"
        fi
        unset _cs_root
    fi
    export VERSION
fi

# BIN_TEST, VERSION and PRINTER are read by the test files, not by this helper.
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

    # Version under test: inherited from environment or resolved from BIN_TEST
    if [ -z "${VERSION:-}" ]; then
        if [ -x "${BIN_TEST}" ]; then
            VERSION="$("${BIN_TEST}" version 2>/dev/null || true)"
        fi
        if [ -z "${VERSION:-}" ] &&
           [ -f "${PROJECT_ROOT}/src/glaipnir.sh" ]; then
            VERSION="$(sed -n 's/^IMG_TAG="\([^"]*\)"/\1/p' \
                "${PROJECT_ROOT}/src/glaipnir.sh" 2>/dev/null || true)"
        fi
    fi
    export VERSION
}
