#!/usr/bin/env bats

# Host command proxy: proxy listener setup, token and port generation,
# allow-list permissions, bin shims, access control in proxy-wrapper.sh,
# and end-to-end execution with proxy-bin.sh.
# The script under test is "$BIN_TEST", see test_helper/common-setup.bash.

setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1
    unset GLAIPNIR_PROXY_PORT GLAIPNIR_PROXY_TOKEN GLAIPNIR_PROXY_HOST

    # Place a dummy tool in PATH for proxy execution tests
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/dummytool" << 'EOF'
#!/bin/sh
printf 'args: %s\n' "$*"
printf 'pwd: %s\n' "$PWD"
exit "${DUMMY_RC:-0}"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/dummytool"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export PATH

    WRAPPER_P="$BATS_TEST_DIRNAME/../proxy/proxy-wrapper.sh"
    SHIM_P="$BATS_TEST_DIRNAME/../proxy/proxy-bin.sh"
    CTN="ai-agents-sandbox-claude"
}

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

# Send a raw request to proxy-wrapper.sh.
# ARGUMENTS:
#   1 - token: received token
#   2 - base: container workspace base
#   3 - cwd: container cwd
#   4 - tool: tool name
#   5 - count: argument count
#   @ - arguments to the tool
_call_wrapper() {
    local _token="$1"
    local _base="$2"
    local _cwd="$3"
    local _tool="$4"
    local _count="$5"
    shift 5
    {
        printf '%s\0' "$_token" "$_base" "$_cwd" "$_tool" "$_count"
        for _arg in "$@"; do
            printf '%s\0' "$_arg"
        done
    } | bash "$WRAPPER_P"
}

# =============================================================================
# CLI and configuration options: --cmd, CMD, CMDS
# =============================================================================

@test "run encodes proxy command spaces as + and deduplicates" {
    stub_fake_socat
    export PODMAN_STUB_RUN_HOOK='cp -r "$XDG_CACHE_HOME/glaipnir/run" \
        "$BATS_TEST_TMPDIR/saved_run"'
    run "$BIN_TEST" run -vv claude --no-microvm --workspace "$WS" \
        --cmd "dummytool run test" --cmd "dummytool run test"
    assert_success
    assert_output \
        --partial "Starting proxy listener for commands: dummytool+run+test"
    refute_output --partial "dummytool+run+test dummytool+run+test"

    [ -d "$BATS_TEST_TMPDIR/saved_run/$CTN" ]
    _allow="$BATS_TEST_TMPDIR/saved_run/$CTN/allowed_commands.list"
    [ -f "$_allow" ]
    grep -Fxq "dummytool run test" "$_allow"
    [ "$(grep -Fxc "dummytool run test" "$_allow")" -eq 1 ]
}

@test "run rejects empty --cmd on command line" {
    run "$BIN_TEST" run claude --no-microvm --workspace "$WS" --cmd ""
    assert_failure 1
    assert_output --partial "Error: --cmd requires an argument."
    refute_run_called
}

@test "run rejects empty CMD in configuration file" {
    _write_conf "CMD="
    run "$BIN_TEST" run claude --no-microvm --workspace "$WS"
    assert_failure 1
    assert_output --partial "Proxy command cannot be empty."
    assert_output --partial "Failed to parse configuration file"
    refute_run_called
}

@test "run accepts CMDS block in configuration file" {
    stub_fake_socat
    export PODMAN_STUB_RUN_HOOK='cp -r "$XDG_CACHE_HOME/glaipnir/run" \
        "$BATS_TEST_TMPDIR/saved_run"'
    _write_conf "CMDS=(" "  dummytool status" "  dummytool diff" ")"
    glaipnir_run_no_microvm claude
    assert_success
    _allow="$BATS_TEST_TMPDIR/saved_run/$CTN/allowed_commands.list"
    [ -f "$_allow" ]
    grep -Fxq "dummytool status" "$_allow"
    grep -Fxq "dummytool diff" "$_allow"
}

# =============================================================================
# Listener startup, port selection, and token generation
# =============================================================================

@test "run warns and fails when socat is missing" {
    mkdir -p "$BATS_TEST_TMPDIR/bin_no_socat"
    IFS=:
    for dir in $PATH; do
        for f in "$dir"/*; do
            [ -x "$f" ] || continue
            bn="$(basename "$f")"
            [ "$bn" = "socat" ] && continue
            [ -e "$BATS_TEST_TMPDIR/bin_no_socat/$bn" ] && continue
            ln -s "$f" "$BATS_TEST_TMPDIR/bin_no_socat/$bn" 2>/dev/null || true
        done
    done
    unset IFS
    PATH="$BATS_TEST_TMPDIR/bin_no_socat" run "$BIN_TEST" run claude \
        --no-microvm --workspace "$WS" --cmd "dummytool run"
    assert_failure 1
    assert_output --partial "Some tools are missing on your system: socat"
    refute_run_called
}

@test "proxy listener selects a free port in 1024-65535 and binds to 127.0.0.1" {
    stub_fake_socat
    glaipnir_run_no_microvm claude --cmd "dummytool run"
    assert_success
    _port="$(run_opt_values --env | sed -n 's/^GLAIPNIR_PROXY_PORT=//p')"
    [ -n "$_port" ]
    [ "$_port" -ge 1024 ] && [ "$_port" -le 65535 ]

    [ -s "$SOCAT_STUB_LOG" ]
    _socat_cmd="$(cat "$SOCAT_STUB_LOG")"
    [[ "$_socat_cmd" == *"bind=127.0.0.1"* ]]
    [[ "$_socat_cmd" == *"TCP-LISTEN:${_port},bind=127.0.0.1,reuseaddr,fork"* ]]
    [[ "$_socat_cmd" == *"EXEC:"*"proxy-wrapper.sh"* ]]
}

@test "proxy token is 32 hex characters and differs at each run" {
    stub_fake_socat
    glaipnir_run_no_microvm claude --cmd "dummytool run"
    assert_success
    assert_run_opt_match --env '^GLAIPNIR_PROXY_TOKEN=[0-9a-f]{32}$'
    _tok1="$(run_opt_values --env | sed -n 's/^GLAIPNIR_PROXY_TOKEN=//p')"

    glaipnir_run_no_microvm claude --cmd "dummytool run"
    assert_success
    _tok2="$(run_opt_values --env | sed -n 's/^GLAIPNIR_PROXY_TOKEN=//p')"

    [ -n "$_tok1" ] && [ -n "$_tok2" ]
    [ "$_tok1" != "$_tok2" ]
}

# =============================================================================
# Run directory permissions, allow-list, and shims
# =============================================================================

@test "proxy run directory is mode 700 and allow-list is mode 600 with defaults" {
    stub_fake_socat
    export PODMAN_STUB_RUN_HOOK='cp -r "$XDG_CACHE_HOME/glaipnir/run" \
        "$BATS_TEST_TMPDIR/saved_run"'
    glaipnir_run_no_microvm claude --cmd "dummytool run"
    assert_success

    _run_d="$BATS_TEST_TMPDIR/saved_run/$CTN"
    [ -d "$_run_d" ]
    _run_mode="$(file_mode "$_run_d")"
    [ "$_run_mode" = "700" ]

    _allow_f="$_run_d/allowed_commands.list"
    [ -f "$_allow_f" ]
    _allow_mode="$(file_mode "$_allow_f")"
    [ "$_allow_mode" = "600" ]

    grep -Fxq "git rev-parse" "$_allow_f"
    grep -Fxq "git describe" "$_allow_f"
    grep -Fxq "dummytool run" "$_allow_f"
}

@test "proxy shim bin/<cmd> is created and mounted read-only" {
    stub_fake_socat
    export PODMAN_STUB_RUN_HOOK='cp -r "$XDG_CACHE_HOME/glaipnir/run" \
        "$BATS_TEST_TMPDIR/saved_run"'
    glaipnir_run_no_microvm claude --cmd "dummytool run"
    assert_success

    _shim_f="$BATS_TEST_TMPDIR/saved_run/$CTN/bin/dummytool"
    [ -f "$_shim_f" ]
    [ -x "$_shim_f" ]
    _shim_mode="$(file_mode "$_shim_f")"
    [ "$_shim_mode" = "755" ]

    assert_run_opt --volume \
        "$XDG_CACHE_HOME/glaipnir/run/$CTN/bin/dummytool:/usr/local/bin/dummytool:ro,z"
    assert_run_opt --env "GLAIPNIR_PROXY_HOST=127.0.0.1"
}

@test "several --cmd create one shim each and deduplicate by binary" {
    stub_fake_socat
    cat > "$BATS_TEST_TMPDIR/bin/othertool" << 'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/othertool"

    export PODMAN_STUB_RUN_HOOK='cp -r "$XDG_CACHE_HOME/glaipnir/run" \
        "$BATS_TEST_TMPDIR/saved_run"'
    glaipnir_run_no_microvm claude \
        --cmd "dummytool run" \
        --cmd "dummytool status" \
        --cmd "othertool check"
    assert_success

    _bin_d="$BATS_TEST_TMPDIR/saved_run/$CTN/bin"
    [ -f "$_bin_d/dummytool" ]
    [ -f "$_bin_d/othertool" ]
    [ "$(find "$_bin_d" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ]

    assert_run_opt --volume \
        "$XDG_CACHE_HOME/glaipnir/run/$CTN/bin/dummytool:/usr/local/bin/dummytool:ro,z"
    assert_run_opt --volume \
        "$XDG_CACHE_HOME/glaipnir/run/$CTN/bin/othertool:/usr/local/bin/othertool:ro,z"
}

# =============================================================================
# Listener cleanup
# =============================================================================

@test "proxy listener and run directory are cleaned up on normal exit" {
    stub_fake_socat
    glaipnir_run_no_microvm claude --cmd "dummytool run"
    assert_success
    [ -s "$SOCAT_PID_F" ]
    stub_kill_fake_socat || fail "the proxy listener is still running"
    [ ! -e "$XDG_CACHE_HOME/glaipnir/run/$CTN" ]
}

@test "proxy listener and run directory are cleaned up on error exit" {
    stub_fake_socat
    export PODMAN_STUB_FAIL="run"
    glaipnir_run_no_microvm claude --cmd "dummytool run"
    assert_failure 1
    [ -s "$SOCAT_PID_F" ]
    stub_kill_fake_socat || fail "the proxy listener is still running"
    [ ! -e "$XDG_CACHE_HOME/glaipnir/run/$CTN" ]
}

# =============================================================================
# Access control and security of proxy-wrapper.sh
# =============================================================================

@test "proxy wrapper refuses requests with wrong or missing token" {
    export GLAIPNIR_PROXY_TOKEN="correct_token_12345"
    export GLAIPNIR_PROXY_ALLOWLIST="$BATS_TEST_TMPDIR/allow.list"
    export GLAIPNIR_HOST_WORKSPACE="$WS"
    printf "dummytool run\n" > "$GLAIPNIR_PROXY_ALLOWLIST"

    # Wrong token
    run _call_wrapper "wrong_token" "/ws" "/ws" "dummytool" "1" "run"
    assert_failure 1
    assert_output --partial "Glaipnir Security Error: Unauthorized proxy access."
    assert_output --partial "__GLAIPNIR_RC_wrong_token__:1"

    # Missing expected token in environment
    unset GLAIPNIR_PROXY_TOKEN
    run _call_wrapper "correct_token_12345" "/ws" "/ws" "dummytool" "1" "run"
    assert_failure 1
    assert_output --partial "Glaipnir Security Error: Unauthorized proxy access."
}

@test "proxy wrapper validates argument count and tool name" {
    export GLAIPNIR_PROXY_TOKEN="valid_token_12345"
    export GLAIPNIR_PROXY_ALLOWLIST="$BATS_TEST_TMPDIR/allow.list"
    export GLAIPNIR_HOST_WORKSPACE="$WS"
    printf "dummytool run\n" > "$GLAIPNIR_PROXY_ALLOWLIST"

    # Non-numeric argument count
    run _call_wrapper "$GLAIPNIR_PROXY_TOKEN" "/ws" "/ws" "dummytool" "invalid"
    assert_failure 1
    assert_output --partial "Glaipnir Proxy Error: Invalid argument count."

    # Missing tool name
    run _call_wrapper "$GLAIPNIR_PROXY_TOKEN" "/ws" "/ws" "" "0"
    assert_failure 1
    assert_output --partial "Glaipnir Proxy Error: Missing tool name."
}

@test "proxy wrapper refuses commands not in the allow-list" {
    export GLAIPNIR_PROXY_TOKEN="valid_token_12345"
    export GLAIPNIR_PROXY_ALLOWLIST="$BATS_TEST_TMPDIR/allow.list"
    export GLAIPNIR_HOST_WORKSPACE="$WS"
    printf "dummytool run\n" > "$GLAIPNIR_PROXY_ALLOWLIST"

    # Unlisted command
    run _call_wrapper "$GLAIPNIR_PROXY_TOKEN" "/ws" "/ws" "dummytool" "1" "evil"
    assert_failure 1
    assert_output \
        --partial "Glaipnir Security Error: Command 'dummytool evil' is not whitelisted."
    assert_output --partial "__GLAIPNIR_RC_${GLAIPNIR_PROXY_TOKEN}__:1"

    # Missing allowlist file
    rm -f "$GLAIPNIR_PROXY_ALLOWLIST"
    run _call_wrapper "$GLAIPNIR_PROXY_TOKEN" "/ws" "/ws" "dummytool" "1" "run"
    assert_failure 1
    assert_output --partial "Command 'dummytool run' is not whitelisted."
}

@test "proxy wrapper executes binary directly without shell interpretation" {
    export GLAIPNIR_PROXY_TOKEN="valid_token_12345"
    export GLAIPNIR_PROXY_ALLOWLIST="$BATS_TEST_TMPDIR/allow.list"
    export GLAIPNIR_HOST_WORKSPACE="$WS"
    printf "dummytool echo\n" > "$GLAIPNIR_PROXY_ALLOWLIST"

    canary="$BATS_TEST_TMPDIR/pwned"
    rm -f "$canary"

    run _call_wrapper "$GLAIPNIR_PROXY_TOKEN" "/ws" "/ws" "dummytool" "3" \
        "echo" "; touch $canary" "\$(touch $canary)"
    assert_success
    [ ! -e "$canary" ]
    assert_output --partial "args: echo ; touch $canary \$(touch $canary)"
    assert_output --partial "__GLAIPNIR_RC_${GLAIPNIR_PROXY_TOKEN}__:0"
}

@test "proxy wrapper restricts working directory to the workspace" {
    export GLAIPNIR_PROXY_TOKEN="valid_token_12345"
    export GLAIPNIR_PROXY_ALLOWLIST="$BATS_TEST_TMPDIR/allow.list"
    export GLAIPNIR_HOST_WORKSPACE="$WS"
    printf "dummytool run\n" > "$GLAIPNIR_PROXY_ALLOWLIST"

    # Directory traversal out of workspace
    run _call_wrapper "$GLAIPNIR_PROXY_TOKEN" "/home/aiuser/workspace" \
        "/home/aiuser/workspace/../../../../../../../../../../../../etc" "dummytool" "1" "run"
    assert_failure 1
    assert_output \
        --partial "Glaipnir Security Error: Execution outside of workspace is blocked."

    # Valid subdirectory inside workspace
    mkdir -p "$WS/sub"
    run _call_wrapper "$GLAIPNIR_PROXY_TOKEN" "/home/aiuser/workspace" \
        "/home/aiuser/workspace/sub" "dummytool" "1" "run"
    assert_success
    assert_output --partial "pwd: $WS/sub"

    # Non-existent directory inside workspace
    run _call_wrapper "$GLAIPNIR_PROXY_TOKEN" "/home/aiuser/workspace" \
        "/home/aiuser/workspace/missing_dir" "dummytool" "1" "run"
    assert_failure 1
    assert_output \
        --partial "Glaipnir Error: Directory '$WS/missing_dir' does not exist on host."
}

@test "proxy wrapper reports binary not found or not executable" {
    export GLAIPNIR_PROXY_TOKEN="valid_token_12345"
    export GLAIPNIR_PROXY_ALLOWLIST="$BATS_TEST_TMPDIR/allow.list"
    export GLAIPNIR_HOST_WORKSPACE="$WS"
    printf "nobinary run\n" > "$GLAIPNIR_PROXY_ALLOWLIST"

    run _call_wrapper "$GLAIPNIR_PROXY_TOKEN" "/ws" "/ws" "nobinary" "1" "run"
    assert_failure 1
    assert_output \
        --partial "Glaipnir Error: Binary 'nobinary' not found or not executable on host."
}

# =============================================================================
# Proxy client shim (proxy-bin.sh) and end-to-end communication
# =============================================================================

@test "proxy-bin.sh fails when port or token is missing" {
    run bash "$SHIM_P"
    assert_failure 1
    assert_output \
        --partial "Glaipnir Error: Proxy configuration missing (PORT or TOKEN not set)."
}

@test "proxy-bin.sh communicates end-to-end with proxy-wrapper.sh over socat" {
    command -v socat >/dev/null 2>&1 || skip "socat is not installed"

    export GLAIPNIR_PROXY_TOKEN="valid_token_12345"
    export GLAIPNIR_PROXY_ALLOWLIST="$BATS_TEST_TMPDIR/allow.list"
    export GLAIPNIR_HOST_WORKSPACE="$WS"
    printf "dummytool run\n" > "$GLAIPNIR_PROXY_ALLOWLIST"

    _port=29876
    socat -d0 "TCP-LISTEN:${_port},bind=127.0.0.1,reuseaddr,fork" \
        "EXEC:${WRAPPER_P}" 2>/dev/null &
    _socat_pid=$!
    sleep 0.1

    export GLAIPNIR_PROXY_PORT="$_port"
    export GLAIPNIR_PROXY_HOST="127.0.0.1"
    export AI_WORKSPACE="$WS"

    mkdir -p "$BATS_TEST_TMPDIR/shims"
    cp "$SHIM_P" "$BATS_TEST_TMPDIR/shims/dummytool"

    run "$BATS_TEST_TMPDIR/shims/dummytool" run
    kill "$_socat_pid" 2>/dev/null || true
    wait "$_socat_pid" 2>/dev/null || true

    assert_success
    assert_output --partial "args: run"
    assert_output --partial "pwd: $WS"
    refute_output --partial "__GLAIPNIR_RC_"
}

@test "proxy-bin.sh propagates non-zero exit code of host command" {
    command -v socat >/dev/null 2>&1 || skip "socat is not installed"

    export GLAIPNIR_PROXY_TOKEN="valid_token_12345"
    export GLAIPNIR_PROXY_ALLOWLIST="$BATS_TEST_TMPDIR/allow.list"
    export GLAIPNIR_HOST_WORKSPACE="$WS"
    export DUMMY_RC=42
    printf "dummytool run\n" > "$GLAIPNIR_PROXY_ALLOWLIST"

    _port=29877
    socat -d0 "TCP-LISTEN:${_port},bind=127.0.0.1,reuseaddr,fork" \
        "EXEC:${WRAPPER_P}" 2>/dev/null &
    _socat_pid=$!
    sleep 0.1

    export GLAIPNIR_PROXY_PORT="$_port"
    export GLAIPNIR_PROXY_HOST="127.0.0.1"
    export AI_WORKSPACE="$WS"

    mkdir -p "$BATS_TEST_TMPDIR/shims"
    cp "$SHIM_P" "$BATS_TEST_TMPDIR/shims/dummytool"

    run "$BATS_TEST_TMPDIR/shims/dummytool" run
    kill "$_socat_pid" 2>/dev/null || true
    wait "$_socat_pid" 2>/dev/null || true

    assert_failure 42
    assert_output --partial "args: run"
    refute_output --partial "__GLAIPNIR_RC_"
}
