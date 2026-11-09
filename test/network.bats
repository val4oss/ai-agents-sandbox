#!/usr/bin/env bats

# Network of 'glaipnir run': pasta bound to the public interface (VPN leak
# protection), the proxy port and the DNS servers.
# podman and ip are stubs (test/test_helper/stubs): IP_STUB_ROUTE gives the
# output of 'ip route show default'.
# The script under test is "$BIN_TEST", see test_helper/common-setup.bash.

# Interfaces that are never used as the public one
VPN_IFACES="tun0 wg0 vpn0 tap0 ppp0 openvpn docker0 br-1a2b3c"

# Run before each test. The libraries have to be loaded here: a 'load' done in
# setup_file() would not define its functions in the process of the tests.
setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1
    unset IP_STUB_ROUTE
}

# Run after each test: never leave a fake listener behind
teardown() {
    stub_kill_fake_socat
}

# Write the configuration file of the test.
# ARGUMENTS:
#   @ - lines of the file
_write_conf() {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    printf '%s\n' "$@" > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
}

# Print the number of --dns options given to 'podman run'.
_dns_count() {
    run_opt_values --dns | wc -l
}

# ==================
# Public interface
# ------------------

@test "run binds pasta to the public interface of the default route" {
    export IP_STUB_ROUTE="default via 198.51.100.1 dev enp3s0 proto dhcp"
    glaipnir_run_no_microvm claude
    assert_success
    assert_output --partial "Binding outbound to interface: enp3s0"
    assert_run_opt --network "pasta:--outbound-if4,enp3s0"
}

@test "run ignores the default routes of VPN and virtual interfaces" {
    for _vpn in $VPN_IFACES; do
        export IP_STUB_ROUTE="default via 10.8.0.1 dev $_vpn
default via 192.0.2.1 dev eth1 metric 600"
        glaipnir_run_no_microvm claude
        assert_success
        assert_run_opt --network "pasta:--outbound-if4,eth1"
    done
}

@test "run keeps the first public interface when there are several" {
    export IP_STUB_ROUTE="default via 192.0.2.1 dev eth1 metric 100
default via 192.0.2.2 dev eth2 metric 200"
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --network "pasta:--outbound-if4,eth1"
}

@test "run is aborted when the only default route is a VPN" {
    for _vpn in $VPN_IFACES; do
        rm -f "$PODMAN_STUB_RUN_LOG"
        export IP_STUB_ROUTE="default via 10.8.0.1 dev $_vpn proto static"
        glaipnir_run_no_microvm claude
        assert_failure 1
        assert_output --partial "Could not detect a non-VPN interface"
        assert_output --partial "Aborting to avoid unrestricted egress"
        refute_run_called
    done
}

@test "run is aborted for a VPN route written without a gateway" {
    # 'ip route' prints no 'via' for the routes of a tunnel
    for _route in "default dev wg0 scope link" \
        "default dev tun0 scope link metric 50" \
        "default dev tun0 proto static scope link"; do
        rm -f "$PODMAN_STUB_RUN_LOG"
        export IP_STUB_ROUTE="$_route"
        glaipnir_run_no_microvm claude
        assert_failure 1
        assert_output --partial "Aborting to avoid unrestricted egress"
        refute_run_called
    done
}

@test "run uses the public interface of a route without a gateway" {
    export IP_STUB_ROUTE="default dev wlan0 scope link metric 600"
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --network "pasta:--outbound-if4,wlan0"
}

@test "run is aborted when there is no default route" {
    export IP_STUB_ROUTE=""
    glaipnir_run_no_microvm claude
    assert_failure 1
    assert_output --partial "Aborting to avoid unrestricted egress"
    refute_run_called
}

@test "run without ip is aborted and starts nothing" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    for cmd in sh bash cat rm mkdir touch dirname basename realpath sed grep \
        tr sort head cut tar xargs wc od mv cp find awk readlink uname id; do
        p="$(command -v "$cmd" 2>/dev/null || true)"
        [ -n "$p" ] && ln -s "$p" "$BATS_TEST_TMPDIR/bin/$cmd"
    done
    ln -s "$BATS_TEST_DIRNAME/test_helper/stubs/podman" \
        "$BATS_TEST_TMPDIR/bin/podman"
    ln -s "$BATS_TEST_DIRNAME/test_helper/stubs/passt" \
        "$BATS_TEST_TMPDIR/bin/passt"
    PATH="$BATS_TEST_TMPDIR/bin" run "$BIN_TEST" run claude --no-microvm \
        --workspace "$WS"
    assert_failure 1
    assert_output --partial "Some tools are missing on your system: ip"
    refute_run_called
}

@test "microVM run without ip nor route is aborted" {
    [ -x /usr/bin/krun ] || skip "krun is not installed"
    [ -c /dev/kvm ] || skip "KVM is not available"
    id -Gn | tr ' ' '\n' | grep -qx kvm || skip "user not in the kvm group"
    # No ip and no route: only the tools needed by glaipnir and krun
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    for cmd in sh bash cat rm mkdir touch dirname basename realpath sed grep \
        tr sort head cut tar xargs wc od mv cp find awk readlink uname id \
        krun; do
        p="$(command -v "$cmd" 2>/dev/null || true)"
        [ -n "$p" ] && ln -s "$p" "$BATS_TEST_TMPDIR/bin/$cmd"
    done
    ln -s "$BATS_TEST_DIRNAME/test_helper/stubs/podman" \
        "$BATS_TEST_TMPDIR/bin/podman"
    PATH="$BATS_TEST_TMPDIR/bin" run "$BIN_TEST" run claude \
        --workspace "$WS" </dev/null
    assert_failure 1
    assert_output --partial "Could not detect a non-VPN interface"
    refute_run_called
}

@test "run does not execute an interface name with shell metacharacters" {
    for _n in 1 2 3; do
        rm -f "$PODMAN_STUB_RUN_LOG"
        case "$_n" in
            1) _if="eth0\`touch\${IFS}${HOME}/pwned1\`" ;;
            2) _if="eth0\$(touch\${IFS}${HOME}/pwned2)" ;;
            3) _if="eth0';touch\${IFS}${HOME}/pwned3;'" ;;
        esac
        export IP_STUB_ROUTE="default via 192.0.2.1 dev $_if"
        glaipnir_run_no_microvm claude
        assert_success
        [ ! -e "$HOME/pwned$_n" ]
        assert_run_opt --network "pasta:--outbound-if4,$_if"
    done
}

# ================
# VPN protection
# ----------------

@test "VPN protection is on by default" {
    glaipnir_run_no_microvm claude
    assert_success
    refute_output --partial "VPN leak protection is disabled"
    assert_run_opt_match --network "--outbound-if4,"
}

@test "--no-vpn-protection warns and uses plain pasta" {
    glaipnir_run_no_microvm claude --no-vpn-protection
    assert_success
    assert_output --partial "VPN leak protection is disabled"
    assert_output --partial "unrestricted egress"
    assert_run_opt --network pasta
    refute_output --partial "Binding outbound to interface"
}

@test "VPN_PROTECTION=0 in the configuration disables the protection" {
    _write_conf "VPN_PROTECTION=0"
    glaipnir_run_no_microvm claude
    assert_success
    assert_output --partial "VPN leak protection is disabled"
    assert_run_opt --network pasta
}

@test "--no-vpn-protection runs even when the only route is a VPN" {
    export IP_STUB_ROUTE="default via 10.8.0.1 dev tun0"
    glaipnir_run_no_microvm claude --no-vpn-protection
    assert_success
    assert_run_opt --network pasta
}

# ============
# Proxy port
# ------------

@test "run adds the proxy port to the pasta options" {
    stub_fake_socat
    glaipnir_run_no_microvm claude --cmd "git status"
    assert_success
    _port="$(printf '%s\n' "$output" |
        sed -n 's/.*listener on 127\.0\.0\.1:\([0-9]*\)\.\.\..*/\1/p')"
    [ -n "$_port" ]
    [ "$_port" -ge 1024 ] && [ "$_port" -le 65535 ]
    assert_run_opt --network "pasta:--outbound-if4,eth0,-T,$_port"
}

@test "run gives only the proxy port to pasta without VPN protection" {
    stub_fake_socat
    glaipnir_run_no_microvm claude --cmd "git status" --no-vpn-protection
    assert_success
    _port="$(printf '%s\n' "$output" |
        sed -n 's/.*listener on 127\.0\.0\.1:\([0-9]*\)\.\.\..*/\1/p')"
    [ -n "$_port" ]
    assert_run_opt --network "pasta:-T,$_port"
}

@test "run without proxy command does not open a port for pasta" {
    glaipnir_run_no_microvm claude
    assert_success
    refute_run_opt_match --network ",-T,"
}

# ====
# DNS
# ----

@test "run gives the default DNS servers when none is set" {
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --dns 1.1.1.1
    assert_run_opt --dns 8.8.8.8
    [ "$(_dns_count)" -eq 2 ]
}

@test "run combines the DNS of the configuration and --dns" {
    _write_conf "DNS=9.9.9.9"
    glaipnir_run_no_microvm claude --dns 1.0.0.1
    assert_success
    assert_run_opt --dns 9.9.9.9
    assert_run_opt --dns 1.0.0.1
    # the defaults are used only when nothing is set
    refute_run_opt_match --dns '^(1\.1\.1\.1|8\.8\.8\.8)$'
    [ "$(_dns_count)" -eq 2 ]
}

@test "run accumulates the DNS of the configuration" {
    _write_conf "DNS=9.9.9.9" "DNS=149.112.112.112"
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --dns 9.9.9.9
    assert_run_opt --dns 149.112.112.112
    [ "$(_dns_count)" -eq 2 ]
}

@test "run gives every DNS server as its own --dns option" {
    glaipnir_run_no_microvm claude --dns 9.9.9.9 --dns 1.0.0.1
    assert_success
    assert_run_opt --dns 9.9.9.9
    assert_run_opt --dns 1.0.0.1
    [ "$(_dns_count)" -eq 2 ]
}
