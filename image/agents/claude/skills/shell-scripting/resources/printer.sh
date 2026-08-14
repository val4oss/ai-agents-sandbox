#!/bin/sh
# printer - Library for printing log messages.
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

# ================
# Global variables
# ----------------

QUIET=0
VERBOSE=0

# Colours are mid-tone on purpose: they keep a contrast ratio above 3.5:1
# on a white *and* on a black background, so the output stays readable in
# light and dark terminal themes. Bright/bold variants are avoided, they
# wash out on light themes (yellow being the worst offender). Only the tag
# is coloured, the message keeps the terminal default foreground colour.
_C_WARN=""
_C_ERR=""
_C_INFO=""
_C_DEBG=""
_C_OFF=""

# =================
# Private functions
# -----------------

###
# Set the colour palette according to the terminal capabilities.
# Honours NO_COLOR (https://no-color.org) and disables colours when the
# output is not a terminal.
# OUTPUTS:
#   sets the _C_* global variables
###
_init_colors() {
    _ncolors=0
    if [ -z "${NO_COLOR}" ] && [ -t 1 ]; then
        _ncolors=$(tput colors 2>/dev/null) || _ncolors=0
    fi
    case "${_ncolors}" in
        *[!0-9]*|"") _ncolors=0 ;;
    esac

    if [ "${_ncolors}" -ge 256 ]; then
        _C_WARN="\033[38;5;166m"    # amber
        _C_ERR="\033[38;5;160m"     # red
        _C_INFO="\033[38;5;29m"     # green
        _C_DEBG="\033[38;5;32m"     # blue
        _C_OFF="\033[0m"
    elif [ "${_ncolors}" -ge 8 ]; then
        _C_WARN="\033[0;33m"
        _C_ERR="\033[0;31m"
        _C_INFO="\033[0;32m"
        _C_DEBG="\033[0;34m"
        _C_OFF="\033[0m"
    fi
    unset _ncolors
}

###
# Print a tagged message.
# ARGUMENTS:
#   1 - colour escape sequence of the tag
#   2 - tag
#   3 - message to print
# OUTPUTS:
#   tagged message on stdout
###
_print() {
    printf "%b%s%b %s\n" "$1" "$2" "${_C_OFF}" "$3"
}

# ================
# Public functions
# ----------------

###
# Print a warning message
# ARGUMENTS:
#   1 - message to print
# OUTPUTS:
#   warning message
###
print_warning() {
    [ "$QUIET" -eq 1 ] && return
    _print "${_C_WARN}" "[WARN]" "$1"
}

###
# Print a error message
# ARGUMENTS:
#   1 - message to print
# OUTPUTS:
#   error message
###
print_error() {
    _print "${_C_ERR}" " [ERR]" "$1" >&2
}

###
# Print a info message
# ARGUMENTS:
#   1 - message to print
# OUTPUTS:
#   info message
###
print_info() {
    [ "$QUIET" -eq 1 ] && return
    _print "${_C_INFO}" "[INFO]" "$1"
}

###
# Print a info message
# ARGUMENTS:
#   1 - message to print
# OUTPUTS:
#   info message
###
print_debug() {
    [ "$VERBOSE" -eq 0 ] && return
    _print "${_C_DEBG}" "[DEBG]" "$1"
}

_init_colors
