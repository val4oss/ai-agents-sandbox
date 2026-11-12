#!/usr/bin/env bats

setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1
}

@test "each trusted agent is accepted; agy is an alias of antigravity" {
    for agent in copilot claude gemini opencode antigravity pi; do
        glaipnir_run_no_microvm "$agent"
        assert_success
        assert_run_arg "ai-agents-sandbox-${agent}:latest"
    done

    glaipnir_run_no_microvm agy
    assert_success
    assert_run_arg "ai-agents-sandbox-antigravity:latest"
}

@test "unknown agent: error listing the valid agents, exit 1" {
    for _bad in unknown-agent pi-bold; do
        run "$BIN_TEST" run --workspace "$WS" "$_bad"
        assert_failure 1
        assert_output --partial "Unknown agent: '$_bad'. Valid agents:"
        assert_output --partial "-Trusted: copilot claude gemini opencode antigravity agy pi"
        assert_output --partial "-Untrusted: hermes-agent"
    done
}

@test "several agents are deduplicated, sorted, joined with - in the image and container names" {
    glaipnir_run_no_microvm gemini copilot gemini agy antigravity pi
    assert_success
    assert_run_arg "ai-agents-sandbox-antigravity-copilot-gemini-pi:latest"
    assert_run_opt "--name" "ai-agents-sandbox-antigravity-copilot-gemini-pi"
}

@test "no agent on build: all trusted agents; untrusted one never included" {
    run "$BIN_TEST" build
    assert_success
    assert_output \
        --partial "Building container image ai-agents-sandbox:${VERSION}"
    grep -q "BUILD_AGENTS=copilot claude gemini opencode antigravity agy pi" "$PODMAN_STUB_LOG"
    ! grep -q "hermes-agent" "$PODMAN_STUB_LOG"
}

@test "hermes-agent on build/run: disclaimer prompt; answer n (or EOF) exits 1" {
    run "$BIN_TEST" run --workspace "$WS" hermes-agent < /dev/null
    assert_failure 1
    assert_output --partial "The agent 'hermes-agent' is considered UNTRUSTED"
}

@test "hermes-agent on build/run: answer y continues" {
    # Write 'y' to a file to pass to stdin, to avoid bash command substitution blocks
    echo 'y' > "$BATS_TEST_TMPDIR/yes.txt"
    run "$BIN_TEST" run --workspace "$WS" --no-microvm hermes-agent < "$BATS_TEST_TMPDIR/yes.txt"
    assert_success
    assert_output --partial "The agent 'hermes-agent' is considered UNTRUSTED"
    assert_run_arg "ai-agents-sandbox-hermes-agent:latest"
}

@test "hermes-agent on status/clean do not prompt" {
    run "$BIN_TEST" status hermes-agent < /dev/null
    assert_success
    refute_output --partial "The agent 'hermes-agent' is considered UNTRUSTED"
}

@test "agent given on the CLI overrides AGENT/AGENTS of the config" {
    cat << 'CONF' > "$BATS_TEST_TMPDIR/conf"
AGENTS=(
    gemini
    copilot
)
CONF
    run "$BIN_TEST" --conf "$BATS_TEST_TMPDIR/conf" run --workspace "$WS" --no-microvm opencode
    assert_success
    assert_run_arg "ai-agents-sandbox-opencode:latest"
}
