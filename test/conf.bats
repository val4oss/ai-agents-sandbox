#!/usr/bin/env bats

setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1
}

# =================
# Config Locations
# -----------------

@test "default config location XDG_CONFIG_HOME/glaipnir/glaipnir.conf is used" {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    cat << 'EOF' > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
AGENT=copilot
DNS=9.9.9.9
EOF
    glaipnir_run_no_microvm
    assert_success
    assert_run_arg "ai-agents-sandbox-copilot:latest"
    assert_run_opt "--dns" "9.9.9.9"
}

@test "--conf overrides default config location" {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    cat << 'EOF' > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
AGENT=copilot
EOF
    cat << 'EOF' > "$BATS_TEST_TMPDIR/custom.conf"
AGENT=gemini
EOF
    glaipnir_run_no_microvm --conf "$BATS_TEST_TMPDIR/custom.conf"
    assert_success
    assert_run_arg "ai-agents-sandbox-gemini:latest"
}

@test "--conf missing or unreadable file causes failure" {
    run "$BIN_TEST" --conf "$BATS_TEST_TMPDIR/nonexistent.conf" run --workspace "$WS" --no-microvm claude
    assert_failure 1
    assert_output --partial "Failed to parse configuration file"

    touch "$BATS_TEST_TMPDIR/unreadable.conf"
    chmod 000 "$BATS_TEST_TMPDIR/unreadable.conf"
    run "$BIN_TEST" --conf "$BATS_TEST_TMPDIR/unreadable.conf" run --workspace "$WS" --no-microvm claude
    assert_failure 1
    assert_output --partial "Failed to parse configuration file"
}

@test "--conf without argument is an error" {
    run "$BIN_TEST" --conf
    assert_failure 1
    assert_output --partial "Error: --conf requires an argument"
}

@test "legacy ai-agents-sandbox.conf is used with a warning when glaipnir.conf is absent" {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    cat << 'EOF' > "$XDG_CONFIG_HOME/glaipnir/ai-agents-sandbox.conf"
AGENT=opencode
EOF
    glaipnir_run_no_microvm
    assert_success
    assert_output --partial "Using legacy config ai-agents-sandbox.conf"
    assert_output --partial "Rename it to glaipnir.conf"
    assert_run_arg "ai-agents-sandbox-opencode:latest"
}

# ====================
# Syntax and Parsing
# --------------------

@test "comments, blank lines, and leading whitespace are handled" {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    cat << 'EOF' > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
# This is a comment
    # Indented comment

   AGENT=pi
   DNS=1.0.0.1
EOF
    glaipnir_run_no_microvm
    assert_success
    assert_run_arg "ai-agents-sandbox-pi:latest"
    assert_run_opt "--dns" "1.0.0.1"
}

@test "quotes are stripped from values" {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    cat << 'EOF' > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
AGENT="claude"
DNS='8.8.4.4'
EOF
    glaipnir_run_no_microvm
    assert_success
    assert_run_arg "ai-agents-sandbox-claude:latest"
    assert_run_opt "--dns" "8.8.4.4"
}

@test "unknown keys in config are ignored" {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    cat << 'EOF' > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
UNKNOWN_KEY=foobar
ANOTHER_KEY="something"
UNKNOWN_BLOCK=(
    foo
    bar
)
AGENT=gemini
EOF
    glaipnir_run_no_microvm
    assert_success
    assert_run_arg "ai-agents-sandbox-gemini:latest"
}

@test "invalid agent in config file causes parse failure" {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    cat << 'EOF' > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
AGENT=invalidagent
EOF
    run "$BIN_TEST" run --workspace "$WS" --no-microvm
    assert_failure 1
    assert_output --partial "Unknown agent: 'invalidagent'"
    assert_output --partial "Failed to parse configuration file"
}

@test "value containing equal sign is kept whole" {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    cat << 'EOF' > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
AGENT=claude
CMD="git config --get=user.name"
EOF
    glaipnir_run_no_microvm
    assert_success
    # In run.log, check the proxy shim for git config
    assert_run_opt_match --volume "git"
}

# =========================
# Scalar and Block Keys
# -------------------------

@test "scalar keys set expected parameters" {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    mkdir -p "$BATS_TEST_TMPDIR/custom_ws" "$BATS_TEST_TMPDIR/custom_cache"
    # Seed fake ADC file for Vertex/GCloud
    mkdir -p "$XDG_CONFIG_HOME/gcloud"
    touch "$XDG_CONFIG_HOME/gcloud/application_default_credentials.json"

    cat << EOF > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
AGENT=claude
USE_MICROVM=0
GCLOUD_PROJECT=my-project-123
GCLOUD_REGION=us-central1
VPN_PROTECTION=0
WORKSPACE=$BATS_TEST_TMPDIR/custom_ws
CACHE=$BATS_TEST_TMPDIR/custom_cache
DNS=9.9.9.9
EOF
    # Run without specifying workspace or no-microvm explicitly on CLI
    run "$BIN_TEST" run
    assert_success
    assert_run_arg "ai-agents-sandbox-claude:latest"
    assert_run_opt "--env" "GOOGLE_CLOUD_PROJECT=my-project-123"
    assert_run_opt "--env" "CLOUDSDK_CORE_PROJECT=my-project-123"
    assert_run_opt "--dns" "9.9.9.9"
    assert_run_opt_match --volume "^$BATS_TEST_TMPDIR/custom_ws:"
    assert_run_opt_match --volume "^$BATS_TEST_TMPDIR/custom_cache/agents-mount/"
    # plain pasta due to VPN_PROTECTION=0
    assert_run_opt "--network" "pasta"
}

@test "DATA_DIR and DATA_D keys set HOME_DATA_D" {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir" "$BATS_TEST_TMPDIR/mydata"
    # Seed agents-mount so save-data has something to archive
    mkdir -p "$XDG_CACHE_HOME/glaipnir/agents-mount"
    echo test > "$XDG_CACHE_HOME/glaipnir/agents-mount/file"

    cat << EOF > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
DATA_DIR=$BATS_TEST_TMPDIR/mydata
EOF
    run "$BIN_TEST" save-data
    assert_success
    run find "$BATS_TEST_TMPDIR/mydata" -name 'glaipnir-data-*.tar.gz'
    assert_output --regexp 'glaipnir-data-.*\.tar\.gz'

    # Test DATA_D variant
    rm -rf "$BATS_TEST_TMPDIR/mydata"/*
    cat << EOF > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
DATA_D=$BATS_TEST_TMPDIR/mydata
EOF
    run "$BIN_TEST" save-data
    assert_success
    run find "$BATS_TEST_TMPDIR/mydata" -name 'glaipnir-data-*.tar.gz'
    assert_output --regexp 'glaipnir-data-.*\.tar\.gz'
}

@test "block keys parse packages, repos, agents, ro_mounts, and cmds" {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    mkdir -p "$HOME/ro1" "$HOME/ro2"
    cat << EOF > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
AGENTS=(
    claude
    gemini
)
PACKAGES=(
    ripgrep
    fd
)
REPOS=(
    https://example.com/repo
)
RO_MOUNTS=(
    $HOME/ro1
    $HOME/ro2:/opt/ro2:ro
)
CMDS=(
    git status
    git diff
)
EOF
    glaipnir_run_no_microvm
    assert_success
    assert_run_arg "ai-agents-sandbox-claude-gemini:latest"
    assert_run_opt "--volume" "$HOME/ro1:/home/aiuser/ro1:ro,z"
    assert_run_opt "--volume" "$HOME/ro2:/opt/ro2:ro,z"

    # Also check build receives PACKAGES and REPOS
    run "$BIN_TEST" build
    assert_success
    grep -q "PKGS= ripgrep fd" "$PODMAN_STUB_LOG"
    grep -q "REPOS= https://example.com/repo" "$PODMAN_STUB_LOG"
}

# ========================
# Per-Workspace Config
# ------------------------

@test "per-workspace .glaipnir.conf is read when workspace is non-default and --conf is not given" {
    mkdir -p "$BATS_TEST_TMPDIR/custom_project"
    cat << 'EOF' > "$BATS_TEST_TMPDIR/custom_project/.glaipnir.conf"
DNS=1.2.3.4
AGENT=opencode
EOF
    glaipnir_run_no_microvm claude --workspace "$BATS_TEST_TMPDIR/custom_project"
    assert_success
    assert_output --partial "Using workspace configuration file:"
    assert_run_opt "--dns" "1.2.3.4"
}

@test "per-workspace .glaipnir.conf is ignored when --conf is explicitly given" {
    mkdir -p "$BATS_TEST_TMPDIR/custom_project"
    cat << 'EOF' > "$BATS_TEST_TMPDIR/custom_project/.glaipnir.conf"
DNS=1.2.3.4
EOF
    cat << 'EOF' > "$BATS_TEST_TMPDIR/override.conf"
DNS=5.6.7.8
EOF
    glaipnir_run_no_microvm claude --workspace "$BATS_TEST_TMPDIR/custom_project" --conf "$BATS_TEST_TMPDIR/override.conf"
    assert_success
    refute_output --partial "Using workspace configuration file:"
    assert_run_opt "--dns" "5.6.7.8"
    refute_run_opt_match --dns "^1\.2\.3\.4$"
}

# =========================
# Sample Config & Security
# -------------------------

@test "the sample ai-agents-sandbox.conf of the repo parses successfully" {
    run "$BIN_TEST" --conf "$PROJECT_ROOT/ai-agents-sandbox.conf" build claude
    assert_success
    grep -q "PKGS= osc quilt rpm-build go" "$PODMAN_STUB_LOG"
}

@test "a config value is not executed by the shell" {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    cat << EOF > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
AGENT=claude
WORKSPACE=\$(touch $BATS_TEST_TMPDIR/executed_dollar)
DNS=\`touch $BATS_TEST_TMPDIR/executed_backtick\`
EOF
    run "$BIN_TEST" run --workspace "$WS" --no-microvm
    [ ! -e "$BATS_TEST_TMPDIR/executed_dollar" ]
    [ ! -e "$BATS_TEST_TMPDIR/executed_backtick" ]
}
