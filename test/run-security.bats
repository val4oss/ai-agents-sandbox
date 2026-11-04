#!/usr/bin/env bats

# Security of the 'podman run' command built by 'glaipnir run'.
# podman is a stub (test/test_helper/stubs): nothing is started, only the
# arguments are recorded and checked.

setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
}

# =========================
# Hardening of the container
# --------------------------

@test "run drops all the capabilities" {
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --cap-drop ALL
    refute_run_opt_match --cap-add '.*'
}

@test "run forbids to gain privileges" {
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --security-opt no-new-privileges
}

@test "run does not weaken the security options" {
    glaipnir_run_no_microvm claude
    assert_success
    refute_run_opt_match --security-opt 'unconfined|label[=:]disable'
    refute_run_arg --privileged
    refute_run_arg --device
    refute_run_arg --pid
    refute_run_arg --ipc
    refute_run_arg --uts
    refute_run_arg --group-add
}

@test "run maps the user with keep-id" {
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --userns keep-id
}

@test "run limits the number of processes" {
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --pids-limit 1024
}

@test "run mounts /tmp as a noexec tmpfs" {
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt_match --tmpfs '^/tmp:.*noexec'
    assert_run_opt_match --tmpfs '^/tmp:.*nosuid'
    assert_run_opt_match --tmpfs '^/tmp:.*nodev'
}

@test "run sets the hostname and the user environment" {
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --hostname ai-sandbox
    assert_run_opt --env AI_USER=aiuser
    assert_run_opt --env AI_UID=1000
    assert_run_opt --env AI_GID=1000
    assert_run_opt --env AI_WORKSPACE=/home/aiuser/ws
    assert_run_opt_match --env '^AI_SANDBOX_VERSION=.+'
}

# ======
# Network
# -------

@test "run uses pasta bound to the public interface" {
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --network 'pasta:--outbound-if4,eth0'
}

@test "run never uses the host or the default network" {
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt_match --network '^pasta'
    refute_run_opt_match --network 'host|bridge|slirp4netns|none'
    refute_run_arg --net
    refute_run_arg --network=host
}

@test "run keeps plain pasta without VPN protection" {
    glaipnir_run_no_microvm claude --no-vpn-protection
    assert_success
    assert_run_opt --network pasta
}

# ========
# Volumes
# --------

@test "run mounts the workspace" {
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --volume "${WS}:/home/aiuser/ws:z"
}

@test "run never mounts a sensitive host path" {
    glaipnir_run_no_microvm claude
    assert_success
    _srcs="$(run_opt_values --volume | cut -d: -f1)"
    [ -n "$_srcs" ]
    for _bad in / /etc /root /var /var/run /run /proc /sys /dev "$HOME" \
        "$REAL_HOME"; do
        [ -n "$_bad" ] || continue
        ! printf '%s\n' "$_srcs" | grep -Fxq -- "$_bad" ||
            fail "sensitive path mounted: $_bad"
    done
    if printf '%s\n' "$_srcs" |
        grep -Eq 'podman\.sock|docker\.sock|^/(etc|root|proc|sys|dev|run)(/|$)'
    then
        fail "sensitive path mounted:"$'\n'"$_srcs"
    fi
}

@test "run labels every mount and shares no propagation" {
    glaipnir_run_no_microvm claude
    assert_success
    _vols="$(run_opt_values --volume)"
    [ -n "$_vols" ]
    # every volume carries the SELinux private label
    _bad="$(printf '%s\n' "$_vols" | grep -vE ':(ro,)?z$' || true)"
    [ -z "$_bad" ] || fail "mount without ':z' label:"$'\n'"$_bad"
    if printf '%s\n' "$_vols" | grep -Eq 'shared|slave|bind-propagation'; then
        fail "mount propagation set:"$'\n'"$_vols"
    fi
}

# =======
# MicroVM
# -------

@test "run without microVM sets no krun option" {
    glaipnir_run_no_microvm claude
    assert_success
    refute_run_arg --runtime
    refute_run_arg --annotation
    refute_run_arg --rm
}

@test "run with microVM uses krun with its limits" {
    glaipnir_run_microvm claude
    assert_success
    assert_run_opt --runtime krun
    assert_run_arg --rm
    assert_run_opt --annotation krun.ram_mib=8192
    assert_run_opt --annotation krun.cpus=4
}

# ========
# Per agent
# ---------

@test "run gives opencode a dedicated exec tmpfs" {
    glaipnir_run_no_microvm opencode
    assert_success
    assert_run_opt_match --tmpfs '^/run/agent-tmp:.*size=512m'
    assert_run_opt --env BUN_TMPDIR=/run/agent-tmp
    # /tmp itself stays noexec
    assert_run_opt_match --tmpfs '^/tmp:.*noexec'
}

@test "run gives the other agents no extra tmpfs" {
    for _agent in claude gemini copilot pi; do
        glaipnir_run_no_microvm "$_agent"
        assert_success
        refute_run_opt_match --tmpfs 'agent-tmp'
        refute_run_opt_match --env '^BUN_TMPDIR='
    done
}

# =============
# Host secrets
# -------------

@test "run does not forward the host environment" {
    export ANTHROPIC_API_KEY="sk-secret-anthropic"
    export GH_TOKEN="ghp_secret_token"
    export GITHUB_TOKEN="ghs_secret_token"
    export OPENAI_API_KEY="sk-secret-openai"
    export GEMINI_API_KEY="secret-gemini"
    glaipnir_run_no_microvm claude
    assert_success
    if grep -q 'secret' "$PODMAN_STUB_RUN_LOG"; then
        fail "host secret forwarded:"$'\n'"$(cat "$PODMAN_STUB_RUN_LOG")"
    fi
}

@test "run only sets the known environment variables" {
    glaipnir_run_no_microvm claude
    assert_success
    _names="$(run_opt_values --env | cut -d= -f1 | sort | tr '\n' ' ')"
    [ "$_names" = \
      "AI_GID AI_SANDBOX_VERSION AI_UID AI_USER AI_WORKSPACE " ]
}

# =====================
# Name of image and ctn
# ---------------------

@test "run names the container and the image after the agent" {
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --name ai-agents-sandbox-claude
    [ "$(tail -n 1 "$PODMAN_STUB_RUN_LOG")" = \
      "ai-agents-sandbox-claude:latest" ]
}

@test "run names the image after all the agents, sorted" {
    glaipnir_run_no_microvm gemini claude
    assert_success
    assert_run_opt --name ai-agents-sandbox-claude-gemini
    [ "$(tail -n 1 "$PODMAN_STUB_RUN_LOG")" = \
      "ai-agents-sandbox-claude-gemini:latest" ]
}

@test "run starts a single container" {
    glaipnir_run_no_microvm claude
    assert_success
    [ "$(grep -c '^run ' "$PODMAN_STUB_LOG")" -eq 1 ]
}
