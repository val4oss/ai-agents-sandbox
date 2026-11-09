#!/usr/bin/env bats

# Google Cloud (Vertex AI) of 'glaipnir run': how it is enabled, how the
# project and the region are found, the ADC file and the variables given to the
# container.
# podman and gcloud are stubs (test/test_helper/stubs): nothing is started.
# The script under test is "$BIN_TEST", see test_helper/common-setup.bash.

# Run before each test. The libraries have to be loaded here: a 'load' done in
# setup_file() would not define its functions in the process of the tests.
setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1
    ADC="$XDG_CONFIG_HOME/gcloud/application_default_credentials.json"
    ADC_DST="/home/aiuser/.config/gcloud/application_default_credentials.json"
    # What glaipnir reads when it asks a question: nothing, by default
    : > "$BATS_TEST_TMPDIR/answers"
}

# Write the configuration file of the test.
# ARGUMENTS:
#   @ - lines of the file
_write_conf() {
    mkdir -p "$XDG_CONFIG_HOME/glaipnir"
    printf '%s\n' "$@" > "$XDG_CONFIG_HOME/glaipnir/glaipnir.conf"
}

# Create the ADC file at its default place.
_adc() {
    mkdir -p "$(dirname "$ADC")"
    printf '{}\n' > "$ADC"
}

# Run 'glaipnir run claude' without microVM. The answers to the questions are
# read from the file $BATS_TEST_TMPDIR/answers.
# ARGUMENTS:
#   @ - options given to glaipnir
_run_gcloud() {
    run "$BIN_TEST" run --no-microvm --workspace "$WS" claude "$@" \
        < "$BATS_TEST_TMPDIR/answers"
}

# Fail unless the container gets the Vertex variables of this project/region.
# ARGUMENTS:
#   1 - project: project ID
#   2 - region: region
_assert_vertex_env() {
    assert_run_opt --env "GOOGLE_CLOUD_PROJECT=$1"
    assert_run_opt --env "ANTHROPIC_VERTEX_PROJECT_ID=$1"
    assert_run_opt --env "CLOUDSDK_CORE_PROJECT=$1"
    assert_run_opt --env "CLAUDE_CODE_USE_VERTEX=1"
    assert_run_opt --env "CLOUD_ML_REGION=$2"
    assert_run_opt --env "VERTEX_LOCATION=$2"
}

# Fail if the container got any Vertex variable or the ADC file.
_refute_vertex() {
    refute_run_opt_match --env \
        'GOOGLE_CLOUD|VERTEX|CLOUDSDK|CLOUD_ML_REGION'
    refute_run_mount_of "$ADC"
}

# ===========
# Enabling
# -----------

@test "run without gcloud option gives nothing about Google Cloud" {
    _adc
    export GOOGLE_CLOUD_PROJECT=env-project VERTEX_LOCATION=global
    _run_gcloud
    assert_success
    _refute_vertex
}

@test "run --gcloud gives the Vertex variables and the ADC file" {
    _adc
    export GOOGLE_CLOUD_PROJECT=env-project VERTEX_LOCATION=global
    _run_gcloud --gcloud
    assert_success
    _assert_vertex_env env-project global
    assert_run_opt --volume "$ADC:$ADC_DST:ro,z"
}

@test "run --gcloud-project enables gcloud with this project" {
    _adc
    export GCLOUD_REGION=eu-west1
    _run_gcloud --gcloud-project cli-project
    assert_success
    _assert_vertex_env cli-project eu-west1
}

@test "USE_GCLOUD=1 in the configuration enables gcloud" {
    _adc
    _write_conf "USE_GCLOUD=1" "GCLOUD_REGION=us-east5"
    export GOOGLE_CLOUD_PROJECT=env-project
    _run_gcloud
    assert_success
    _assert_vertex_env env-project us-east5
}

@test "GCLOUD_PROJECT in the configuration enables gcloud" {
    _adc
    _write_conf "GCLOUD_PROJECT=conf-project" "GCLOUD_REGION=us-east5"
    _run_gcloud
    assert_success
    _assert_vertex_env conf-project us-east5
}

@test "USE_GCLOUD=0 in the configuration keeps gcloud disabled" {
    _adc
    _write_conf "USE_GCLOUD=0"
    export GOOGLE_CLOUD_PROJECT=env-project VERTEX_LOCATION=global
    _run_gcloud
    assert_success
    _refute_vertex
}

@test "run --no-gcloud wins over --gcloud and the configuration" {
    _adc
    _write_conf "USE_GCLOUD=1" "GCLOUD_PROJECT=conf-project"
    _run_gcloud --gcloud --gcloud-project cli-project --no-gcloud
    assert_success
    _refute_vertex
}

# ===================
# Project resolution
# -------------------

@test "the project is searched in the variables in this order" {
    _adc
    export GCLOUD_REGION=global
    export GCLOUD_STUB_PROJECT=gcloud-project
    export ANTHROPIC_VERTEX_PROJECT_ID=vertex-project
    export GOOGLE_CLOUD_PROJECT=google-project
    export GCLOUD_PROJECT=gcloud-var-project
    _run_gcloud --gcloud
    assert_success
    assert_run_opt --env "GOOGLE_CLOUD_PROJECT=gcloud-var-project"
    unset GCLOUD_PROJECT
    _run_gcloud --gcloud
    assert_success
    assert_run_opt --env "GOOGLE_CLOUD_PROJECT=google-project"
    unset GOOGLE_CLOUD_PROJECT
    _run_gcloud --gcloud
    assert_success
    assert_run_opt --env "GOOGLE_CLOUD_PROJECT=vertex-project"
    unset ANTHROPIC_VERTEX_PROJECT_ID
    _run_gcloud --gcloud
    assert_success
    assert_run_opt --env "GOOGLE_CLOUD_PROJECT=gcloud-project"
}

@test "the project of the configuration wins over the environment" {
    _adc
    export GCLOUD_REGION=global GOOGLE_CLOUD_PROJECT=google-project
    _write_conf "GCLOUD_PROJECT=conf-project"
    _run_gcloud
    assert_success
    assert_run_opt --env "GOOGLE_CLOUD_PROJECT=conf-project"
}

@test "gcloud is not asked when a variable gives the project" {
    _adc
    export GCLOUD_REGION=global GOOGLE_CLOUD_PROJECT=google-project
    export GCLOUD_STUB_LOG="$BATS_TEST_TMPDIR/gcloud.log"
    _run_gcloud --gcloud
    assert_success
    [ ! -s "$GCLOUD_STUB_LOG" ]
}

@test "the project of gcloud is read with config get-value" {
    _adc
    export GCLOUD_REGION=global GCLOUD_STUB_PROJECT=gcloud-project
    export GCLOUD_STUB_LOG="$BATS_TEST_TMPDIR/gcloud.log"
    _run_gcloud --gcloud
    assert_success
    assert_run_opt --env "GOOGLE_CLOUD_PROJECT=gcloud-project"
    grep -Fxq "config get-value project" "$GCLOUD_STUB_LOG"
}

@test "an unset project of gcloud is ignored and the project is asked" {
    _adc
    export GCLOUD_REGION=global GCLOUD_STUB_PROJECT="(unset)"
    printf 'asked-project\n' > "$BATS_TEST_TMPDIR/answers"
    _run_gcloud --gcloud
    assert_success
    assert_output --partial "Google Cloud Project ID needed for Vertex AI"
    assert_run_opt --env "GOOGLE_CLOUD_PROJECT=asked-project"
}

@test "the project and the region are asked when nothing gives them" {
    _adc
    printf 'asked-project\nasked-region\n' > "$BATS_TEST_TMPDIR/answers"
    _run_gcloud --gcloud
    assert_success
    assert_output --partial "Google Cloud Project ID needed for Vertex AI"
    assert_output --partial "Google Cloud Region needed for Vertex AI"
    _assert_vertex_env asked-project asked-region
}

@test "run is refused when the project or the region is not given" {
    _adc
    # nobody answers
    _run_gcloud --gcloud
    assert_failure 1
    refute_run_called
    # the project is known, the region is not
    rm -f "$PODMAN_STUB_RUN_LOG"
    export GOOGLE_CLOUD_PROJECT=google-project
    _run_gcloud --gcloud
    assert_failure 1
    refute_run_called
}

# ====================
# Region resolution
# --------------------

@test "the region is searched in the variables in this order" {
    _adc
    export GOOGLE_CLOUD_PROJECT=google-project
    export CLOUD_ML_REGION=r5 GOOGLE_CLOUD_REGION=r4
    export ANTHROPIC_VERTEX_LOCATION=r3 VERTEX_LOCATION=r2 GCLOUD_REGION=r1
    for _r in r1 r2 r3 r4 r5; do
        _run_gcloud --gcloud
        assert_success
        assert_run_opt --env "CLOUD_ML_REGION=$_r"
        assert_run_opt --env "VERTEX_LOCATION=$_r"
        case "$_r" in
            r1) unset GCLOUD_REGION ;;
            r2) unset VERTEX_LOCATION ;;
            r3) unset ANTHROPIC_VERTEX_LOCATION ;;
            r4) unset GOOGLE_CLOUD_REGION ;;
        esac
    done
}

@test "the region of the configuration is used" {
    _adc
    export GOOGLE_CLOUD_PROJECT=google-project VERTEX_LOCATION=env-region
    _write_conf "GCLOUD_REGION=conf-region"
    _run_gcloud --gcloud
    assert_success
    assert_run_opt --env "VERTEX_LOCATION=conf-region"
}

# ===================
# --gcloud-project
# -------------------

@test "--gcloud-project wins over GCLOUD_PROJECT of the configuration" {
    _adc
    export GCLOUD_REGION=global
    _write_conf "GCLOUD_PROJECT=conf-project"
    _run_gcloud --gcloud-project cli-project
    assert_success
    assert_run_opt --env "GOOGLE_CLOUD_PROJECT=cli-project"
    refute_run_opt_match --env "=conf-project"
}

@test "--gcloud-project wins over the project of the environment" {
    _adc
    export GCLOUD_REGION=global GCLOUD_PROJECT=env-project
    export GOOGLE_CLOUD_PROJECT=google-project
    export ANTHROPIC_VERTEX_PROJECT_ID=vertex-project
    _run_gcloud --gcloud-project cli-project
    assert_success
    _assert_vertex_env cli-project global
}

@test "--gcloud-project wins over GCLOUD_PROJECT of the workspace config" {
    _adc
    export GCLOUD_REGION=global
    mkdir -p "$HOME/proj"
    printf 'GCLOUD_PROJECT=workspace-project\n' > "$HOME/proj/.glaipnir.conf"
    run "$BIN_TEST" run --no-microvm --workspace "$HOME/proj" claude \
        --gcloud-project cli-project < "$BATS_TEST_TMPDIR/answers"
    assert_success
    assert_output --partial "Using workspace configuration file:"
    assert_run_opt --env "GOOGLE_CLOUD_PROJECT=cli-project"
}

@test "--gcloud-project without argument is an error" {
    _run_gcloud --gcloud-project
    assert_failure 1
    assert_output --partial "requires an argument"
    refute_run_called
}

# ============
# ADC file
# ------------

@test "run takes the ADC file of XDG_CONFIG_HOME" {
    _adc
    export GOOGLE_CLOUD_PROJECT=p GCLOUD_REGION=r
    _host_adc="$HOME/.config/gcloud/application_default_credentials.json"
    mkdir -p "$(dirname "$_host_adc")"
    echo decoy > "$_host_adc"
    _run_gcloud --gcloud
    assert_success
    assert_run_opt --volume "$ADC:$ADC_DST:ro,z"
    refute_run_mount_of "$_host_adc"
}

@test "run takes the ADC file of ~/.config without XDG_CONFIG_HOME" {
    _host_adc="$HOME/.config/gcloud/application_default_credentials.json"
    mkdir -p "$(dirname "$_host_adc")"
    echo adc > "$_host_adc"
    export GOOGLE_CLOUD_PROJECT=p GCLOUD_REGION=r
    run env -u XDG_CONFIG_HOME "$BIN_TEST" run --no-microvm --workspace "$WS" \
        claude --gcloud < "$BATS_TEST_TMPDIR/answers"
    assert_success
    assert_run_opt --volume "$_host_adc:$ADC_DST:ro,z"
}

@test "run takes the ADC file of GOOGLE_APPLICATION_CREDENTIALS" {
    _adc
    echo custom > "$BATS_TEST_TMPDIR/custom-adc.json"
    export GOOGLE_APPLICATION_CREDENTIALS="$BATS_TEST_TMPDIR/custom-adc.json"
    export GOOGLE_CLOUD_PROJECT=p GCLOUD_REGION=r
    _run_gcloud --gcloud
    assert_success
    assert_run_opt --volume \
        "$BATS_TEST_TMPDIR/custom-adc.json:$ADC_DST:ro,z"
    refute_run_mount_of "$ADC"
    # the path is the one of the host, it means nothing in the container
    refute_run_opt_match --env "GOOGLE_APPLICATION_CREDENTIALS"
}

@test "run uses the default ADC file when the variable points to nothing" {
    _adc
    export GOOGLE_APPLICATION_CREDENTIALS="$BATS_TEST_TMPDIR/missing.json"
    export GOOGLE_CLOUD_PROJECT=p GCLOUD_REGION=r
    _run_gcloud --gcloud
    assert_success
    assert_run_opt --volume "$ADC:$ADC_DST:ro,z"
}

@test "run without ADC file is refused with the login hint" {
    export GOOGLE_CLOUD_PROJECT=p GCLOUD_REGION=r
    _run_gcloud --gcloud
    assert_failure 1
    assert_output --partial "Google ADC file not found"
    assert_output --partial "$ADC"
    assert_output --partial "gcloud auth application-default login"
    refute_run_called
}

@test "run mounts the ADC file read-only and no other gcloud file" {
    _adc
    echo other > "$XDG_CONFIG_HOME/gcloud/credentials.db"
    mkdir -p "$XDG_CONFIG_HOME/gcloud/legacy_credentials"
    export GOOGLE_CLOUD_PROJECT=p GCLOUD_REGION=r
    _run_gcloud --gcloud
    assert_success
    assert_run_opt_match --volume ":ro,z$"
    [ "$(run_opt_values --volume | grep -c ':ro')" -eq 1 ]
    run_opt_values --volume | grep -F "/gcloud" | grep -Fxq "$ADC:$ADC_DST:ro,z"
    [ "$(run_opt_values --volume | grep -Fc "/gcloud")" -eq 1 ]
}

# ===================
# Variables and safety
# --------------------

@test "run gives exactly the six Vertex variables" {
    _adc
    export GOOGLE_CLOUD_PROJECT=p GCLOUD_REGION=r
    _run_gcloud --gcloud
    assert_success
    _assert_vertex_env p r
    _vars="GOOGLE_CLOUD_PROJECT|ANTHROPIC_VERTEX_PROJECT_ID"
    _vars="$_vars|CLOUDSDK_CORE_PROJECT|CLAUDE_CODE_USE_VERTEX"
    _vars="$_vars|CLOUD_ML_REGION|VERTEX_LOCATION"
    [ "$(run_opt_values --env | grep -Ec "^($_vars)=")" -eq 6 ]
}

@test "run does not execute the project and the region" {
    _adc
    export GOOGLE_CLOUD_PROJECT="\$(touch\${IFS}${HOME}/pwned1)"
    export GCLOUD_REGION="x\";touch\${IFS}${HOME}/pwned2;\""
    _run_gcloud --gcloud
    assert_success
    [ ! -e "$HOME/pwned1" ]
    [ ! -e "$HOME/pwned2" ]
    assert_run_opt --env "GOOGLE_CLOUD_PROJECT=$GOOGLE_CLOUD_PROJECT"
    assert_run_opt --env "VERTEX_LOCATION=$GCLOUD_REGION"
}

@test "run does not execute the answers to the questions" {
    _adc
    printf '%s\n' "\$(touch\${IFS}${HOME}/pwned3)" \
        "x\";touch\${IFS}${HOME}/pwned4;\"" > "$BATS_TEST_TMPDIR/answers"
    _run_gcloud --gcloud
    assert_success
    [ ! -e "$HOME/pwned3" ]
    [ ! -e "$HOME/pwned4" ]
}

# ===============
# Existing container
# ---------------

@test "run warns that --gcloud-project is not applied to a container" {
    _adc
    export GCLOUD_REGION=global
    stub_container ai-agents-sandbox-claude exited
    _run_gcloud --gcloud-project cli-project
    assert_success
    assert_output --partial "Vertex env vars are applied only when creating"
}

@test "run warns that --gcloud is not applied to an existing container" {
    _adc
    export GCLOUD_REGION=global
    stub_container ai-agents-sandbox-claude exited
    _run_gcloud --gcloud
    assert_success
    assert_output --partial "Vertex env vars are applied only when creating"
}
