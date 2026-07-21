#!/bin/sh
# Sample example - Sample to show a shell script example.
# Copyright (C) 2026  val4oss <val4oss@pm.me>
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANYWARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# ================
# Global variables
# ----------------

# Return codes
SUCCESS=0
FAILURE=1

# Main variables
PRJ_ID="sample-script"

# Path variables
ROOT_D="$(cd "$(dirname "$0")" && pwd)"

# ========
# Includes
# --------

. "${ROOT_D}/printer.sh"


# ==================
# Internal functions
# ------------------

# description of this internal dunction
_internal_function() {
    _ret="$SUCCESS"
    # ...
    return "$_ret"
}

# ================
# Main functions
# ----------------

# Print usage information
usage() {
    _str="Usage: ${PRJ_ID} [-q|-v|-h] <actions> <agent> [options]
  -q, --quiet   Suppress all output except errors
  -v, --verbose Enable verbose output
  --version     Show version information and exit
  -h, --help    Show this help message and exit

Actions:
  run           Run the sandbox with the specified agent

Options:
  --conf       Defined conf file path for building the image. See Notes.

  Notes:
  - Usefull notes for the script.
"
    printf "%s\n" "$_str"
}

# ===========
# Entry point
# -----------

_check_tools_needed || {
    print_error "Please install the missing tools and try again. Aborting."
    exit $FAILURE
}

# Get arguments
PARSED_ARGUMENTS=$(
    getopt -a -n $PRJ_ID -o c:vh --long conf:,verbose,help -- "$@"
)

eval set -- "$PARSED_ARGUMENTS"
while :
do
  case "$1" in
    -c | --conf)        CONF=$2                     ; shift 2 ;;
    -v | --verbose)     VERBOSE=1                   ; shift 1 ;;
    -h | --help)        usage                       ;;
    --)                 shift                       ; break   ;;
    *)                  print_warning "Unexpected option: $1"; usage   ;;
  esac
done

# Verify that the required arguments are provided
# ...


# Entry point
# ...

exit $SUCCESS
