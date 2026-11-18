#!/usr/bin/env bats

# Logic of 'glaipnir run': tools, microVM fallback, existing containers, image
# pull and build, run hooks, agents configuration reset, failures.
# podman is a stub (test/test_helper/stubs): nothing is started, the calls are
# recorded and checked.
# The script under test is "$BIN_TEST", see test_helper/common-setup.bash.

# Run before each test. The libraries have to be loaded here: a 'load' done in
# setup_file() would not define its functions in the process of the tests.
setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1
    CACHE="$XDG_CACHE_HOME/glaipnir"
    CTN="ai-agents-sandbox-claude"
    REPO="registry.opensuse.org/home/vlefebvre/container-images"
    REPO="$REPO/containers/opensuse"
}

# Run after each test: never leave a fake listener behind
teardown() {
    stub_kill_fake_socat
}

# Write a shell script that passes shellcheck.
# ARGUMENTS:
#   1 - path: file to write
_good_hook() {
    printf '#!/bin/sh\necho "hook"\n' > "$1"
}

# Write a shell script that does not pass shellcheck.
# ARGUMENTS:
#   1 - path: file to write
_bad_hook() {
    printf '#!/bin/sh\nfor f in $(ls); do echo $f; done\n' > "$1"
}

# =======
# Tools
# -------

@test "run without microVM needs passt and ip" {
    [ "$(uname -s)" != "Darwin" ] || skip "passt and ip are Linux-only requirements"
    # A PATH holding the stub of podman only, and the tools glaipnir needs
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    for cmd in sh bash cat rm mkdir touch dirname basename realpath sed grep \
        tr sort head cut tar xargs wc od mv cp find awk readlink uname id; do
        p="$(command -v "$cmd" 2>/dev/null || true)"
        [ -n "$p" ] && ln -s "$p" "$BATS_TEST_TMPDIR/bin/$cmd"
    done
    ln -s "$BATS_TEST_DIRNAME/test_helper/stubs/podman" \
        "$BATS_TEST_TMPDIR/bin/podman"

    PATH="$BATS_TEST_TMPDIR/bin" run "$BIN_TEST" run claude --no-microvm \
        --workspace "$WS"
    assert_failure 1
    assert_output --partial "Some tools are missing on your system:"
    assert_output --partial "passt"
    assert_output --partial "ip"
    assert_output --partial "Required tools for the selected isolation"
    refute_run_called
}

# ==========
# MicroVM
# ----------

@test "run falls back to the container mode when microVM is unavailable" {
    [ "$(uname -s)" != "Darwin" ] || skip "microVM fallback prompt is Linux-specific"
    # Without krun or KVM the check fails before any question to the user
    if [ -x /usr/bin/krun ] && [ -c /dev/kvm ]; then
        skip "this host can run microVMs"
    fi
    run "$BIN_TEST" run claude --workspace "$WS" </dev/null
    assert_success
    assert_output --partial "MicroVM isolation is not available."
    assert_output --partial "Running without it for agent 'claude'"
    refute_run_arg "--runtime"
    refute_run_opt_match --annotation "^krun"
    assert_run_opt --name "$CTN"
}

@test "run names the container with the microvm suffix in microVM mode" {
    glaipnir_run_microvm claude
    assert_success
    assert_run_opt --name "${CTN}-microvm"
}

# ===================
# Existing container
# -------------------

@test "run starts a container that is stopped or not started yet" {
    for _s in exited created initialized configured; do
        rm -f "$PODMAN_STUB_LOG" "$BATS_TEST_TMPDIR/containers"
        stub_container "$CTN" "$_s"
        glaipnir_run_no_microvm claude
        assert_success
        assert_output --partial "Starting container from '$_s'"
        assert_podman_call start -ai "$CTN"
        refute_run_called
    done
}

@test "run attaches to a running container with exec" {
    stub_container "$CTN" running runc
    glaipnir_run_no_microvm claude
    assert_success
    assert_output --partial "Attaching to running container"
    assert_podman_call exec -it "$CTN" bash
    refute_run_called
}

@test "run fails when the start of a stopped container fails" {
    stub_container "$CTN" exited
    export PODMAN_STUB_FAIL="start"
    glaipnir_run_no_microvm claude
    assert_failure 1
}

@test "run fails when the attach to a running container fails" {
    stub_container "$CTN" running
    export PODMAN_STUB_FAIL="exec"
    glaipnir_run_no_microvm claude
    assert_failure 1
}

@test "run creates a new container when a running one uses krun" {
    stub_container "$CTN" running krun
    glaipnir_run_no_microvm claude
    assert_success
    assert_output --partial "Creating a new one with suffix ${CTN}-1"
    assert_run_opt --name "${CTN}-1"
    refute_podman_call exec
}

@test "run takes the first free number for the new krun container" {
    stub_container "$CTN" running krun
    stub_container "${CTN}-1" running krun
    stub_container "${CTN}-2" exited krun
    glaipnir_run_no_microvm claude
    assert_success
    assert_run_opt --name "${CTN}-3"
}

@test "run refuses a container in an unknown state and advises clean" {
    for _s in paused dead removing stopped; do
        rm -f "$PODMAN_STUB_LOG" "$PODMAN_STUB_RUN_LOG" \
            "$BATS_TEST_TMPDIR/containers"
        stub_container "$CTN" "$_s"
        glaipnir_run_no_microvm claude
        assert_failure 1
        assert_output --partial "is in state '$_s'"
        assert_output --partial "Please use 'clean' before 'run'"
        refute_run_called
        refute_podman_call start
        refute_podman_call exec
    done
}

@test "run refuses a stopping container that does not use krun" {
    stub_container "$CTN" stopping runc
    glaipnir_run_no_microvm claude
    assert_failure 1
    assert_output --partial "is in state 'stopping'"
    refute_run_called
}

@test "run warns about the Vertex variables when the container exists" {
    stub_container "$CTN" exited
    GOOGLE_CLOUD_PROJECT=my-project glaipnir_run_no_microvm claude
    assert_success
    assert_output --partial "Vertex env vars are applied only when creating"
    assert_output --partial "Use 'clean claude' then 'run claude'"
    rm -f "$BATS_TEST_TMPDIR/containers" "$PODMAN_STUB_LOG"
    VERTEX_LOCATION=global glaipnir_run_no_microvm claude
    assert_success
    refute_output --partial "Vertex env vars are applied only when creating"
}

@test "run does not warn about the Vertex variables without them" {
    stub_container "$CTN" exited
    glaipnir_run_no_microvm claude
    assert_success
    refute_output --partial "Vertex env vars are applied only when creating"
}

# ============================
# Reset of the agents config
# ----------------------------

@test "run --reset-agent-config resets the config of a stopped container" {
    mkdir -p "$CACHE/agents-mount"
    touch "$CACHE/agents-mount/canary"
    stub_container "$CTN" exited
    glaipnir_run_no_microvm claude --reset-agent-config
    assert_success
    assert_output --partial "Removing the agents configuration"
    [ ! -e "$CACHE/agents-mount/canary" ]
    assert_podman_call start -ai "$CTN"
}

@test "run --reset-agent-config warns and keeps the config when running" {
    mkdir -p "$CACHE/agents-mount"
    touch "$CACHE/agents-mount/canary"
    stub_container "$CTN" running runc
    glaipnir_run_no_microvm claude --reset-agent-config
    assert_success
    assert_output --partial "glaipnir cannot reset"
    [ -e "$CACHE/agents-mount/canary" ]
    assert_podman_call exec -it "$CTN" bash
}

@test "run --reset-agent-config resets the config for a new container" {
    mkdir -p "$CACHE/agents-mount"
    touch "$CACHE/agents-mount/canary"
    glaipnir_run_no_microvm claude --reset-agent-config
    assert_success
    [ ! -e "$CACHE/agents-mount/canary" ]
    [ -d "$CACHE/agents-mount" ]
    assert_run_arg "$CTN:latest"
}

@test "run keeps the agents config without --reset-agent-config" {
    mkdir -p "$CACHE/agents-mount"
    touch "$CACHE/agents-mount/canary"
    glaipnir_run_no_microvm claude
    assert_success
    [ -e "$CACHE/agents-mount/canary" ]
}

# ==========
# Image
# ----------

@test "run with a local image does not pull it" {
    glaipnir_run_no_microvm claude
    assert_success
    refute_podman_call pull
    refute_podman_call build
    assert_run_arg "$CTN:latest"
}

@test "run pulls the image when there is no local one" {
    export PODMAN_STUB_NO_IMAGE=1
    glaipnir_run_no_microvm claude
    assert_success
    assert_output --partial "Pulling image: $REPO/$CTN"
    assert_podman_call pull -q "$REPO/$CTN"
    refute_podman_call build
    assert_run_arg "$CTN:latest"
}

@test "run pulls the image when only the registry one is present" {
    export PODMAN_STUB_IMG_REPO="$REPO/$CTN"
    glaipnir_run_no_microvm claude
    assert_success
    assert_podman_call pull -q "$REPO/$CTN"
    refute_podman_call build
}

@test "run builds the image when the pull fails" {
    export PODMAN_STUB_NO_IMAGE=1
    export PODMAN_STUB_FAIL="pull"
    glaipnir_run_no_microvm claude
    assert_success
    assert_output --partial "No Image built and cannot pull $REPO/$CTN"
    [ -s "$PODMAN_STUB_BUILD_LOG" ]
    assert_run_arg "$CTN:latest"
}

@test "run fails when both the pull and the build fail" {
    export PODMAN_STUB_NO_IMAGE=1
    export PODMAN_STUB_FAIL="pull"
    export PODMAN_STUB_BUILD_FAIL=1
    glaipnir_run_no_microvm claude
    assert_failure 1
    assert_output --partial "Failed to build image $CTN"
    refute_run_called
}

# =========
# Hooks
# ---------

@test "run copies a hook file in the run hooks directory" {
    _good_hook "$BATS_TEST_TMPDIR/my-hook.sh"
    glaipnir_run_no_microvm claude --run-hook "$BATS_TEST_TMPDIR/my-hook.sh"
    assert_success
    [ -f "$CACHE/run-hooks/my-hook.sh" ]
    _hooks_dst="/usr/local/bin/ai-agents-sandbox-run-hooks/:z"
    assert_run_opt --volume "$CACHE/run-hooks:$_hooks_dst"
}

@test "run copies only the NN-*.sh files of a hook directory" {
    _d="$BATS_TEST_TMPDIR/hooks"
    mkdir -p "$_d"
    _good_hook "$_d/10-first.sh"
    _good_hook "$_d/20-second.sh"
    _good_hook "$_d/no-number.sh"
    printf 'text\n' > "$_d/30-not-a-script.txt"
    glaipnir_run_no_microvm claude --run-hook "$_d"
    assert_success
    [ -f "$CACHE/run-hooks/10-first.sh" ]
    [ -f "$CACHE/run-hooks/20-second.sh" ]
    [ ! -e "$CACHE/run-hooks/no-number.sh" ]
    [ ! -e "$CACHE/run-hooks/30-not-a-script.txt" ]
}

@test "run wipes the previous content of the run hooks directory" {
    mkdir -p "$CACHE/run-hooks"
    touch "$CACHE/run-hooks/stale-hook.sh"
    glaipnir_run_no_microvm claude
    assert_success
    [ -d "$CACHE/run-hooks" ]
    [ ! -e "$CACHE/run-hooks/stale-hook.sh" ]
}

@test "run with a hook failing shellcheck is aborted" {
    command -v shellcheck >/dev/null || skip "shellcheck is not installed"
    _bad_hook "$BATS_TEST_TMPDIR/bad.sh"
    glaipnir_run_no_microvm claude --run-hook "$BATS_TEST_TMPDIR/bad.sh"
    assert_failure 1
    assert_output --partial "malformated hook script"
    refute_run_called
}

@test "run is aborted when a hook of a directory fails shellcheck" {
    command -v shellcheck >/dev/null || skip "shellcheck is not installed"
    _d="$BATS_TEST_TMPDIR/hooks"
    mkdir -p "$_d"
    # The failing hook comes first, a good one follows
    _bad_hook "$_d/10-bad.sh"
    _good_hook "$_d/20-good.sh"
    glaipnir_run_no_microvm claude --run-hook "$_d"
    assert_failure 1
    refute_run_called
}

@test "run with a non-existing hook is refused" {
    glaipnir_run_no_microvm claude --run-hook "$BATS_TEST_TMPDIR/missing.sh"
    assert_failure 1
    assert_output --partial "not found"
    refute_run_called
}

# ============
# Workspace
# ------------

@test "run maps a workspace of HOME to the same path in the sandbox" {
    mkdir -p "$HOME/proj/sub"
    run "$BIN_TEST" run claude --no-microvm --workspace "$HOME/proj/sub"
    assert_success
    _src="$(realpath "$HOME")/proj/sub"
    assert_run_opt --volume "$_src:/home/aiuser/proj/sub:z"
    assert_run_opt --env "AI_WORKSPACE=/home/aiuser/proj/sub"
}

@test "run maps a workspace outside HOME to /home/aiuser/workspace" {
    _ws="$BATS_TEST_TMPDIR/outside/ws"
    mkdir -p "$_ws"
    run "$BIN_TEST" run claude --no-microvm --workspace "$_ws"
    assert_success
    assert_run_opt --volume "$(realpath "$_ws"):/home/aiuser/workspace:z"
    assert_run_opt --env "AI_WORKSPACE=/home/aiuser/workspace"
}

@test "run does not take for HOME a path that only contains its string" {
    # HOME is <tmp>/home: <tmp>/home-other is outside, not below
    _ws="$BATS_TEST_TMPDIR/home-other/ws"
    mkdir -p "$_ws"
    run "$BIN_TEST" run claude --no-microvm --workspace "$_ws"
    assert_success
    assert_run_opt --volume "$(realpath "$_ws"):/home/aiuser/workspace:z"
}

# ==========
# Failure
# ----------

@test "run fails when podman run fails" {
    export PODMAN_STUB_FAIL="run"
    glaipnir_run_no_microvm claude
    assert_failure 1
    assert_output --partial "Failed to start container $CTN"
}

@test "run stops the proxy listener when podman run fails" {
    stub_fake_socat
    export PODMAN_STUB_FAIL="run"
    glaipnir_run_no_microvm claude --cmd "git status"
    assert_failure 1
    [ -s "$SOCAT_PID_F" ]
    stub_kill_fake_socat || fail "the proxy listener is still running"
    [ ! -e "$CACHE/run/$CTN" ]
}
