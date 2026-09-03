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
#
# Every message is written on the log channel, the file descriptor 3, opened
# once when this library is sourced. A command substitution only captures the
# standard output, so a log stays visible on the console even when it is
# emitted from inside a "$(...)". The standard output is therefore left free
# to carry the value returned by a function, and the standard error to carry
# the output of the external tools.

# ================
# Global variables
# ----------------

# Return codes, defined here too so that this library stays usable on its own
# whatever the order of the includes of the script sourcing it.
SUCCESS="${SUCCESS:-0}"
FAILURE="${FAILURE:-1}"

QUIET=0
VERBOSE=0

# Log channel destination, 'stderr' by default, so the messages reach the
# console when the script is interactive and the journal when it runs as a
# systemd unit. 'tty' forces the controlling terminal even when the standard
# output and the standard error are both redirected. 'file' appends to
# PRINTER_FILE.
PRINTER_SINK="${PRINTER_SINK:-stderr}"
PRINTER_FILE="${PRINTER_FILE:-}"
# Set by _printer_init(), 1 when the log channel accepts the ANSI colours.
PRINTER_COLOR=0
# Guard, the log channel is opened once even if this library is sourced twice.
PRINTER_READY="${PRINTER_READY:-0}"

# ==================
# Internal functions
# ------------------

###
# Open the log channel on the given target, keep stderr as a fallback
# ARGUMENTS:
#   1 - target : file or device to open the file descriptor 3 on
# OUTPUTS:
#   fd 3 : opened on the target, or on stderr when the target is not writable
###
_printer_open() {
    # The probe runs in a subshell, a failing 'exec' would abort the script.
    if (exec 3>>"$1") 2>/dev/null; then
        exec 3>>"$1"
    else
        exec 3>&2
        printf "[WARN] Cannot open the log channel '%s', using stderr.\n" \
            "$1" >&3
    fi
}

###
# Open the log channel once and detect whether it supports the colours
# OUTPUTS:
#   fd 3 : the log channel, opened according to PRINTER_SINK
###
_printer_init() {
    if [ "$PRINTER_READY" -eq 0 ]; then
        case "$PRINTER_SINK" in
            tty)  _printer_open "/dev/tty"      ;;
            file) _printer_open "$PRINTER_FILE" ;;
            *)    exec 3>&2                     ;;
        esac
        # No escape sequence in a log file nor in the journal.
        PRINTER_COLOR=0
        if [ -t 3 ]; then
            PRINTER_COLOR=1
        fi
        PRINTER_READY=1
    fi
}

###
# Print a tagged message on the log channel
# ARGUMENTS:
#   1 - tag  : level tag, right aligned on 6 characters with its brackets
#   2 - code : ANSI colour code of the level, used on a terminal only
#   3 - msg  : message to print
# OUTPUTS:
#   fd 3 : the formatted message
###
_print() {
    # Reopens the channel when printer_close() has been called before.
    _printer_init
    if [ "$PRINTER_COLOR" -eq 1 ]; then
        printf "%b%6s%b %s%b\n" "\033[0;${2}m" "[$1]" "\033[1;${2}m" "$3" \
            "\033[0m" >&3
    else
        printf "%6s %s\n" "[$1]" "$3" >&3
    fi
}

# ================
# Public functions
# ----------------

###
# Print a warning message
# ARGUMENTS:
#   1 - message to print
# OUTPUTS:
#   fd 3 : warning message, unless the quiet mode is on
###
print_warning() {
    if [ "$QUIET" -ne 1 ]; then
        _print "WARN" "33" "$1"
    fi
}

###
# Print a error message
# ARGUMENTS:
#   1 - message to print
# OUTPUTS:
#   fd 3 : error message, the quiet mode never hides it
###
print_error() {
    _print "ERR" "31" "$1"
}

###
# Print a info message
# ARGUMENTS:
#   1 - message to print
# OUTPUTS:
#   fd 3 : info message, unless the quiet mode is on
###
print_info() {
    if [ "$QUIET" -ne 1 ]; then
        _print "INFO" "32" "$1"
    fi
}

###
# Print a debug message
# ARGUMENTS:
#   1 - message to print
# OUTPUTS:
#   fd 3 : debug message, only when the verbose mode is on
###
print_debug() {
    if [ "$VERBOSE" -ne 0 ]; then
        _print "DEBG" "34" "$1"
    fi
}

###
# Release the log channel
# Useless before exiting, the kernel closes the descriptor anyway. Call it
# when this library is sourced by a long lived shell, or before spawning a
# child that must not inherit the channel. The next print_xxx() reopens it.
# GLOBALS:
#   write: PRINTER_READY
# OUTPUTS:
#   fd 3 : closed
# RETURNS:
#   SUCCESS
###
#printer_close() {
#    _ret="$SUCCESS"
#    exec 3>&-
#    PRINTER_READY=0
#    return "$_ret"
#}

# ===========
# Entry point
# -----------

_printer_init
