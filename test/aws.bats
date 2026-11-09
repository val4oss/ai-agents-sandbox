#!/usr/bin/env bats

# AWS Bedrock authentication of 'glaipnir run': how it is enabled, how the
# profile and region are resolved, granular read-only mounts, and variables
# forwarded to the container.
# podman is stubbed (test/test_helper/stubs): nothing is started.
# The script under test is "$BIN_TEST", see test_helper/common-setup.bash.

setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1

    AWS_DIR="$HOME/.aws"
    AWS_CFG="$AWS_DIR/config"
    AWS_CRED="$AWS_DIR/credentials"
    AWS_SSO="$AWS_DIR/sso/cache"

    AWS_DST_CFG="/home/aiuser/.aws/config"
    AWS_DST_CRED="/home/aiuser/.aws/credentials"
    AWS_DST_SSO="/home/aiuser/.aws/sso/cache"

    # Default answers for interactive prompts
    : > "$BATS_TEST_TMPDIR/answers"
}

# Write the configuration file of the test.
_write_conf() {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    printf '%s\n' "$@" > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
}

# Create standard AWS files in HOME.
_seed_aws() {
    mkdir -p "$AWS_SSO"
    cat > "$AWS_CFG" << 'EOF'
[default]
region = us-east-1

[profile dev]
region = eu-west-1
EOF
    cat > "$AWS_CRED" << 'EOF'
[default]
aws_access_key_id = AKIATEST
aws_secret_access_key = SECRETTEST
EOF
    touch "$AWS_SSO/token.json"
}

# Run 'glaipnir run claude' without microVM.
_run_aws() {
    run "$BIN_TEST" run --no-microvm --workspace "$WS" claude "$@" \
        < "$BATS_TEST_TMPDIR/answers"
}

# Fail unless the container gets the Bedrock variables.
_assert_bedrock_env() {
    local _profile="${1:-default}"
    local _region="${2:-us-east-1}"
    assert_run_opt --env "AWS_PROFILE=$_profile"
    assert_run_opt --env "AWS_REGION=$_region"
    assert_run_opt --env "AWS_DEFAULT_REGION=$_region"
    assert_run_opt --env "CLAUDE_CODE_USE_BEDROCK=1"
}

# Fail if the container got any AWS variable or volume.
_refute_bedrock() {
    refute_run_opt_match --env 'AWS_|CLAUDE_CODE_USE_BEDROCK'
    refute_run_mount_of "$AWS_CFG"
    refute_run_mount_of "$AWS_CRED"
    refute_run_mount_of "$AWS_SSO"
}

# =============================================================================
# Enabling
# =============================================================================

@test "run without aws option gives nothing about AWS" {
    _seed_aws
    export AWS_PROFILE=dev AWS_REGION=eu-central-1
    _run_aws
    assert_success
    _refute_bedrock
}

@test "run --aws gives Bedrock variables and mounts config and credentials" {
    _seed_aws
    _run_aws --aws
    assert_success
    _assert_bedrock_env default us-east-1
    assert_run_opt --volume "$AWS_CFG:$AWS_DST_CFG:ro,z"
    assert_run_opt --volume "$AWS_CRED:$AWS_DST_CRED:ro,z"
    assert_run_opt --volume "$AWS_SSO:$AWS_DST_SSO:ro,z"
}

@test "run --aws-profile enables aws with this profile" {
    _seed_aws
    _run_aws --aws-profile dev
    assert_success
    _assert_bedrock_env dev eu-west-1
}

@test "run --aws-region enables aws with this region" {
    _seed_aws
    _run_aws --aws-region ap-southeast-1
    assert_success
    _assert_bedrock_env default ap-southeast-1
}

@test "USE_AWS=1 in configuration enables aws" {
    _seed_aws
    _write_conf "USE_AWS=1"
    _run_aws
    assert_success
    _assert_bedrock_env default us-east-1
}

@test "AWS_PROFILE in configuration enables aws" {
    _seed_aws
    _write_conf "AWS_PROFILE=dev"
    _run_aws
    assert_success
    _assert_bedrock_env dev eu-west-1
}

@test "USE_AWS=0 in configuration keeps aws disabled" {
    _seed_aws
    _write_conf "USE_AWS=0"
    export AWS_PROFILE=dev AWS_REGION=eu-central-1
    _run_aws
    assert_success
    _refute_bedrock
}

@test "run --no-aws wins over --aws and configuration" {
    _seed_aws
    _write_conf "USE_AWS=1" "AWS_PROFILE=dev"
    _run_aws --aws --no-aws
    assert_success
    _refute_bedrock
}

# =============================================================================
# Profile resolution
# =============================================================================

@test "--aws-profile wins over configuration and environment" {
    _seed_aws
    _write_conf "AWS_PROFILE=from-conf"
    export AWS_PROFILE=from-env
    _run_aws --aws-profile from-cli --aws-region us-east-1
    assert_success
    _assert_bedrock_env from-cli us-east-1
}

@test "AWS_PROFILE in configuration wins over environment" {
    _seed_aws
    _write_conf "AWS_PROFILE=from-conf"
    export AWS_PROFILE=from-env
    _run_aws --aws --aws-region us-east-1
    assert_success
    _assert_bedrock_env from-conf us-east-1
}

@test "AWS_PROFILE from environment is used when not in CLI or config" {
    _seed_aws
    export AWS_PROFILE=dev
    _run_aws --aws
    assert_success
    _assert_bedrock_env dev eu-west-1
}

@test "--aws-profile without argument is an error" {
    run "$BIN_TEST" run --no-microvm --workspace "$WS" claude --aws-profile
    assert_failure 1
    assert_output --partial "Error: --aws-profile requires an argument."
    refute_run_called
}

# =============================================================================
# Region resolution
# =============================================================================

@test "--aws-region wins over configuration, environment, and file" {
    _seed_aws
    _write_conf "AWS_REGION=from-conf"
    export AWS_REGION=from-env
    _run_aws --aws --aws-region from-cli
    assert_success
    _assert_bedrock_env default from-cli
}

@test "AWS_REGION in configuration wins over environment and file" {
    _seed_aws
    _write_conf "AWS_REGION=from-conf"
    export AWS_REGION=from-env
    _run_aws --aws
    assert_success
    _assert_bedrock_env default from-conf
}

@test "AWS_REGION from environment is used when not in CLI or config" {
    _seed_aws
    export AWS_REGION=from-env
    _run_aws --aws
    assert_success
    _assert_bedrock_env default from-env
}

@test "AWS_DEFAULT_REGION from environment is used if AWS_REGION is unset" {
    _seed_aws
    export AWS_DEFAULT_REGION=from-default-env
    _run_aws --aws
    assert_success
    _assert_bedrock_env default from-default-env
}

@test "region is parsed from ~/.aws/config for the profile" {
    _seed_aws
    _run_aws --aws-profile dev
    assert_success
    _assert_bedrock_env dev eu-west-1
}

@test "region is asked interactively when not found anywhere" {
    mkdir -p "$AWS_DIR"
    # Config without region
    cat > "$AWS_CFG" << 'EOF'
[default]
output = json
EOF
    printf "ap-northeast-1\n" > "$BATS_TEST_TMPDIR/answers"
    _run_aws --aws
    assert_success
    _assert_bedrock_env default ap-northeast-1
}

@test "run is refused when region prompt is answered empty" {
    mkdir -p "$AWS_DIR"
    cat > "$AWS_CFG" << 'EOF'
[default]
output = json
EOF
    printf "\n" > "$BATS_TEST_TMPDIR/answers"
    _run_aws --aws
    assert_failure 1
    assert_output --partial "No AWS Region for Bedrock."
    refute_run_called
}

@test "--aws-region without argument is an error" {
    run "$BIN_TEST" run --no-microvm --workspace "$WS" claude --aws-region
    assert_failure 1
    assert_output --partial "Error: --aws-region requires an argument."
    refute_run_called
}

# =============================================================================
# Granular mounts and security
# =============================================================================

@test "run fails with hint when no AWS config or credentials exist" {
    rm -rf "$AWS_DIR"
    _run_aws --aws --aws-region us-east-1
    assert_failure 1
    assert_output --partial "AWS configuration not found in ~/.aws"
    assert_output --partial "aws configure  OR  aws sso login"
    refute_run_called
}

@test "only existing AWS files are mounted and other files are excluded" {
    mkdir -p "$AWS_DIR/cli/cache"
    echo "sensitivedata" > "$AWS_DIR/cli/cache/internal.json"
    echo "othersecret" > "$AWS_DIR/secret.txt"
    cat > "$AWS_CFG" << 'EOF'
[default]
region = us-east-1
EOF

    _run_aws --aws
    assert_success

    # Mounted: config
    assert_run_opt --volume "$AWS_CFG:$AWS_DST_CFG:ro,z"

    # Not mounted: credentials or sso (do not exist)
    refute_run_mount_of "$AWS_CRED"
    refute_run_mount_of "$AWS_SSO"

    # Entire .aws is NOT mounted
    refute_run_mount_of "$AWS_DIR"
    refute_run_mount_of "$AWS_DIR/cli/cache"
    refute_run_mount_of "$AWS_DIR/secret.txt"
}

@test "non-claude agent does not get CLAUDE_CODE_USE_BEDROCK" {
    _seed_aws
    run "$BIN_TEST" run --no-microvm --workspace "$WS" gemini --aws
    assert_success
    assert_run_opt --env "AWS_PROFILE=default"
    assert_run_opt --env "AWS_REGION=us-east-1"
    refute_run_opt_match --env "CLAUDE_CODE_USE_BEDROCK"
}

@test "run warns that AWS Bedrock env vars are not applied to existing container" {
    _seed_aws
    stub_container "ai-agents-sandbox-claude" running
    _run_aws --aws
    assert_success
    assert_output \
        --partial "AWS Bedrock env vars are applied only when creating a new container."
    assert_output \
        --partial "Use 'clean claude' then 'run claude' to apply updates."
}
