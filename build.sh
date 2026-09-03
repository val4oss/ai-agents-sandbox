#!/bin/sh
# builder for the glaipnir tool.
# Copyright (C) 2026  val4oss <val4oss@pm.me>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

if [ "$(uname -s)" = "Darwin" ]; then
    echo "Build not yet supported on MacOS"
    echo "TBD: Add support to MacOS"
    exit 1
fi

# ================
# Global variables
# ----------------

# Return codes
SUCCESS=0
FAILURE=1

PRJ_ID="${PRJ_ID:-glaipnir}"
VERSION="${VERSION:-1.0.0}"

ROOT_D="$(cd "$(dirname "$0")" && pwd)"
SRC_D="${ROOT_D}/src"
SRC_FILES="
${SRC_D}/glaipnir.sh
${SRC_D}/printer.sh
"

BUILD_D="${ROOT_D}/build"

PREFIX="${PREFIX:-/usr/local}"
case "$PREFIX" in
    /*) ;;
    *)  PREFIX="/$PREFIX" ;;
esac

BINDIR="${PREFIX}/bin"
DATADIR="${PREFIX}/share"
PKGDATADIR="${DATADIR}/${PRJ_ID}"
DESTDIR="${DESTDIR:-}"

# ==============
# Main functions
# --------------

###
# Remove the build directory
# GLOBALS:
#   read: BUILD_D
###
build_clean() {
    _rc="${SUCCESS}"
    [ -d "${BUILD_D}" ] && {
        echo "Removing ${BUILD_D} ..."
        rm -r "${BUILD_D}" || _rc="${FAILURE}"
    }
    return "${_rc}"
}

###
# Verify each sources file using shellcheck binary
# GLOBALS:
#   read: SRC_FILES
# OUTPUTS:
#   errors
# RETURNS:
#   SUCCESS, FAILURE
###
build_check() {
    _rc=${SUCCESS}
    if ! command -v shellcheck > /dev/null 2>&1; then
        _rc=${FAILURE}
        echo "Missing shellcheck binary"
    else
        for _src_f in ${SRC_FILES}; do
            if ! shellcheck -x "${_src_f}"; then
                echo "Shellcheck return somes errors/warning for ${_src_f}"
                _rc=${FAILURE}
            fi
        done
    fi
    return "${_rc}"
}

###
# Print the usage helper
# OUTPUTS:
#   usage
###
build_usage() {
    _usage_str="USAGE: $0 [options]
options:
    check:      Use SchellCheck to verify all sources
    install     Install the artefacts built
    uninstall   Uninstall the project
    clean:      Clean build env
    help:       Print this helper
info:
    Build the glaipnir project
    "

    printf "%s\n" "${_usage_str}"
}

###
# Main build function
# OUTPUTS:
#   progress of the build
# RETURNS:
#   SUCCESS, FAILURE if build fails
###
build_main() {
    _rc="${SUCCESS}"
    while true; do

        build_clean || {
            echo "build: Failed to clean"
            _rc="${FAILURE}"; break
        }
        build_check || {
            echo "build: Failed to check"
            _rc="${FAILURE}"; break
        }
        [ -d "${BUILD_D}" ] || mkdir -p "${BUILD_D}" || {
            echo "build: Failed to create ${BUILD_D} dir"
            _rc="${FAILURE}"; break
        }

        mkdir -p "${BUILD_D}${BINDIR}" "${BUILD_D}${PKGDATADIR}" || {
            echo "build: Failed to create staged dirs"
            _rc="${FAILURE}"; break
        }

        # rpm forbids '-' in Version and sorts '~' below the release; OCI tags
        # forbid '~'. Hence two spellings of the same version.
        IMGVERSION="$(echo "${VERSION}" | tr '~' '-')"

        # Replacing include and store the file with good variables
        echo "Building ${BUILD_D}${BINDIR}/${PRJ_ID}"
        _printer_include="\\. \"\\\${ROOT_D}\\/src\\/printer\\.sh\""
        sed \
            -e "/${_printer_include}/r src/printer.sh"              \
            -e "/${_printer_include}/d"                             \
            -e "s|^DATA_D=.*|DATA_D=\"${BUILD_D}${PKGDATADIR}\"|"   \
            -e "/^ROOT_D=.*/d"                                      \
            -e "s|^IMG_TAG=.*|IMG_TAG=\"${IMGVERSION}\"|"           \
            src/glaipnir.sh                                         \
            > "${BUILD_D}${BINDIR}/${PRJ_ID}" || {
                echo "Failed to build ${BINDIR}/${PRJ_ID}"
                _rc="${FAILURE}"; break
            }
        chmod 755 "${BUILD_D}${BINDIR}/${PRJ_ID}" || {
            echo "chmod failed"
            _rc="${FAILURE}"; break
        }
        echo "Building datas ${BUILD_D}${PKGDATADIR}/"
        cp -r image "${BUILD_D}${PKGDATADIR}/image"

        break
    done

    return "${_rc}"
}

###
# Install the project
# GLOBALS:
#   read: BUILD_D DESTDIR BINDIR PKGDATADIR PRJ_ID
# OUTPUTS:
#   status installation output
# RETURNS:
#   SUCCESS, FAILURE if installation fails
###
build_install() {
    _rc=${SUCCESS}

    while true; do

        [ -d "${BUILD_D}" ] || {
            build_main || {
                echo "Failed to build for install"
                _rc="$FAILURE"; break
            }
        }

        for _dir in "${DESTDIR}${BINDIR}" "${DESTDIR}${PKGDATADIR}"; do
            if [ -e "${_dir}" ]; then
                if [ ! -d "${_dir}" ]; then
                    echo "Failed to install: ${_dir} exists and not a directory"
                    _rc="${FAILURE}"; break 2
                fi
            else
                if ! mkdir -p "${_dir}"; then
                    echo "Failed to create ${_dir}"
                    _rc="${FAILURE}"; break 2
                fi
            fi
        done

        sed \
            -e "s|^DATA_D=.*|DATA_D=${PKGDATADIR}|" \
            "${BUILD_D}${BINDIR}/${PRJ_ID}" \
            > "${BUILD_D}${BINDIR}/${PRJ_ID}.install" || {
                echo "Failed to update ${BINDIR}/${PRJ_ID}.install"
                _rc="${FAILURE}"; break
            }

        echo "Installing ${DESTDIR}${BINDIR}/${PRJ_ID} ..."
        install "${BUILD_D}${BINDIR}/${PRJ_ID}.install" \
            "${DESTDIR}${BINDIR}/${PRJ_ID}" || {
                echo "Failed to install binary"
                _rc="${FAILURE}"; break
            }
        rm "${BUILD_D}${BINDIR}/${PRJ_ID}.install"
        echo "Installing ${DESTDIR}${PKGDATADIR} ..."
        (
            cd "${BUILD_D}${PKGDATADIR}" || {
                echo "Built data dir not found"
                exit 1
            }
            find . -type f -exec sh -c '
                if [ -x "$1" ]; then
                    install -Dm 755 "$1" "$2/$1"
                else
                    install -Dm 644 "$1" "$2/$1"
                fi
            ' _ {} "${DESTDIR}${PKGDATADIR}" \;
        ) || {
            echo "Failed to install data dir"
            _rc="${FAILURE}"; break

        }
        break
    done

    return "${_rc}"
}

###
# Uninstall the project
# GLOBALS:
#   read: BUILD_D DESTDIR BINDIR PKGDATADIR PRJ_ID
# OUTPUTS:
#   status uninstallation
# RETURNS:
#   SUCCESS, FAILURE if uninstallation fails
###
build_uninstall() {
    _rc=${SUCCESS}
    _bin_f="${DESTDIR}${BINDIR}/${PRJ_ID}"
    _data_d="${DESTDIR}${PKGDATADIR}"

    while true; do
        if [ -f "${_bin_f}" ]; then
            echo "Uninstalling ${_bin_f} ..."
            rm "${_bin_f}" || {
                echo "Failed to uninstall ${_bin_f}"
                _rc="${FAILURE}"; break
            }
        fi
            echo "Uninstalling ${_data_d}/ ..."
        if [ -d "${_data_d}" ]; then
            rm -r "${_data_d}" || {
                echo "Failed to uninstall ${_data_d}"
                _rc="${FAILURE}"; break
            }
        fi
        break
    done
    return "$_rc"
}

# ===========
# Entry point
# -----------

_action_rc="${SUCCESS}"
if [ "$1" != "" ]; then
    case "$1" in
        help)       build_usage         || _action_rc="${FAILURE}" ;;
        check)      build_check         || _action_rc="${FAILURE}" ;;
        install)    build_install       || _action_rc="${FAILURE}" ;;
        uninstall)  build_uninstall     || _action_rc="${FAILURE}" ;;
        clean)      build_clean         || _action_rc="${FAILURE}" ;;
    esac
    
    if [ "${_action_rc}" -ne "${SUCCESS}" ]; then
        echo "Action $1 Failed."
    fi
else
    build_main || _action_rc="${FAILURE}"
fi
exit "${_action_rc}"
