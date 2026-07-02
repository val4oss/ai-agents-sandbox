#!/bin/sh
# macos-network-policy.sh - macOS VPN route discovery helpers.
# Copyright (C) 2026  git-ival <iramis.valentin@suse.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public
# License along with this program.
# If not, see <https://www.gnu.org/licenses/>.
#
# Sourced by macos-vpn-enforcer.sh and ai-agents-sandbox.sh.
# Not intended to be executed directly.

# return 0 if any VPN connection is active on macOS
_macos_vpn_active() {
    # Method 1: macOS Network Configuration framework
    # (covers Cisco AnyConnect, built-in IKEv2/L2TP, etc.)
    if command -v scutil > /dev/null 2>&1; then
        if scutil --nc list 2>/dev/null \
            | grep -qi 'connected'; then
            return 0
        fi
    fi

    # Method 2: utun/ppp interfaces with an IPv4 address.
    # System-owned utun ifaces (AirDrop, iCloud) carry IPv6 only.
    for _vi in $(ifconfig -l 2>/dev/null \
        | tr ' ' '\n' \
        | grep -E '^(utun|ppp)[0-9]'); do
        if ifconfig "$_vi" 2>/dev/null \
            | grep -q 'inet [0-9]'; then
            return 0
        fi
    done

    return 1
}

# convert macOS netstat route notation to CIDR format
_macos_route_to_cidr() {
    _rt="$1"
    case "$_rt" in
        */*)
            printf '%s\n' "$_rt"
            ;;
        *)
            _rnet="$_rt"
            _rdots=$(printf '%s' "$_rt" \
                | tr -cd '.' | wc -c \
                | tr -d ' ')
            while [ "$_rdots" -lt 3 ]; do
                _rnet="${_rnet}.0"
                _rdots=$(( _rdots + 1 ))
            done
            case "$_rt" in
                *.*.*.*) _rmask=32 ;;
                *.*.*)   _rmask=24 ;;
                *.*)     _rmask=16 ;;
                *)       _rmask=8 ;;
            esac
            printf '%s/%s\n' "$_rnet" "$_rmask"
            ;;
    esac
}

# Discover VPN-routed subnets from the macOS routing table.
# Iterates over every utun/ppp interface that carries an IPv4
# address and collects the specific host/network routes installed
# via that interface (excluding loopback, multicast, broadcast).
#
# On stdout: space-separated CIDR list (only when returning 0).
# Return codes:
#   0  success — CIDRs printed to stdout
#   1  full-tunnel VPN detected (default route via VPN iface)
#   2  VPN is active but no specific routes found
_macos_discover_vpn_routes() {
    _dvr_routes=""
    _dvr_full=0

    for _vi in $(ifconfig -l 2>/dev/null \
        | tr ' ' '\n' \
        | grep -E '^(utun|ppp)[0-9]'); do

        # Skip interfaces without an IPv4 address
        if ! ifconfig "$_vi" 2>/dev/null \
            | grep -q 'inet [0-9]'; then
            continue
        fi

        # Full-tunnel: VPN interface owns the default route
        if netstat -rn -f inet 2>/dev/null \
            | awk -v i="$_vi" \
                '$NF==i && $1=="default" \
                {found=1} END{exit !found}'; then
            _dvr_full=1
            break
        fi

        # Collect split-tunnel routes via this interface
        while IFS= read -r _rt; do
            [ -z "$_rt" ] && continue
            _cidr=$(_macos_route_to_cidr "$_rt")
            if [ -z "$_dvr_routes" ]; then
                _dvr_routes="$_cidr"
            else
                _dvr_routes="$_dvr_routes $_cidr"
            fi
        done << ROUTESEOF
$(netstat -rn -f inet 2>/dev/null \
    | awk -v i="$_vi" \
        '$NF==i && $1!="default" \
        && $1!~/^127/ && $1!~/^224/ \
        && $1!~/^255/ {print $1}')
ROUTESEOF
    done

    if [ "$_dvr_full" = "1" ]; then
        return 1
    fi

    if [ -z "$_dvr_routes" ] && _macos_vpn_active; then
        return 2
    fi

    printf '%s' "$_dvr_routes"
    return 0
}
