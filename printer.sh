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
    color="\033[0;33m"
    color_light="\033[1;33m"
    color_none="\033[0m"
    printf "%b[WARNING]%b %s%b\n" "${color}" "${color_light}" "$1" \
"${color_none}"
}

###
# Print a error message
# ARGUMENTS:
#   1 - message to print
# OUTPUTS:
#   error message
###
print_error() {
    color="\033[0;31m"
    color_light="\033[1;31m"
    color_none="\033[0m"
    printf "%b[ERROR]%b %s%b\n" "${color}" "${color_light}" "$1" "${color_none}" >&2
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
    color="\033[0;32m"
    color_light="\033[1;32m"
    color_none="\033[0m"
    printf "%b[INFO]%b %s%b\n" "${color}" "${color_light}" "$1" "${color_none}"
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
    color="\033[0;34m"
    color_light="\033[1;34m"
    color_none="\033[0m"
    printf "%b[DEBUG]%b %s%b\n" "${color}" "${color_light}" "$1" "${color_none}"
}
