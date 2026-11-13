#!/usr/bin/env bats

# Mounts of the agents configuration of 'glaipnir run': the host files copied
# in the cache, the volumes given to podman, the skel files of the image.
# podman is a stub (test/test_helper/stubs), HOME and the XDG directories are
# fake: nothing of the real configuration of the user is read.
# The script under test is "$BIN_TEST", see test_helper/common-setup.bash.

# Agents that do not need any confirmation
AGENTS_ALL="claude copilot gemini antigravity opencode pi"

# Run before each test. The libraries have to be loaded here: a 'load' done in
# setup_file() would not define its functions in the process of the tests.
setup() {
    load 'test_helper/common-setup'
    _common_setup
    load 'test_helper/podman-stub'
    stub_env "$BATS_TEST_TMPDIR"
    export NO_COLOR=1
    MNT="$XDG_CACHE_HOME/glaipnir/agents-mount"
    # The answer to the question about the untrusted agent hermes-agent
    echo y > "$BATS_TEST_TMPDIR/yes"
}

# Create a file with its parent directories.
# ARGUMENTS:
#   1 - path: file to write
#   2 - content: content of the file, "content" by default
_host() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "${2:-content}" > "$1"
}

# Run 'glaipnir run' without microVM, answering yes to any question.
# ARGUMENTS:
#   @ - agents and options given to glaipnir
_run_agent() {
    run "$BIN_TEST" run --no-microvm --workspace "$WS" "$@" \
        < "$BATS_TEST_TMPDIR/yes"
}

# Create a host file for each agent, its content is its own path.
_seed_host() {
    _host "$HOME/.agents/skills/mine/SKILL.md" "agents"
    _host "$XDG_CONFIG_HOME/gh/hosts.yml" "gh"
    _host "$HOME/.copilot/config.json" "copilot"
    _host "$HOME/.gemini/settings.json" "gemini"
    _host "$HOME/.claude/settings.json" "claude"
    _host "$HOME/.claude.json" "claude-json"
    _host "$XDG_CONFIG_HOME/opencode/opencode.json" "opencode-config"
    _host "$XDG_DATA_HOME/opencode/auth.json" "opencode-data"
    _host "$HOME/.pi/settings.json" "pi"
    _host "$HOME/.hermes/config.yaml" "hermes"
}

# Print the volumes of 'podman run' that come from the agents mount directory,
# the host part relative to it, sorted.
_agent_volumes() {
    run_opt_values --volume |
        awk -v p="$MNT/" \
            'index($0, p) == 1 { print substr($0, length(p) + 1) }' |
        sort
}

# Print the volumes an agent must have, without the ones of every agent.
# ARGUMENTS:
#   1 - agent: agent name
_expected_volumes() {
    case "$1" in
        copilot)
            printf '%s\n' ".config/gh:/home/aiuser/.config/gh:z" \
                ".copilot:/home/aiuser/.copilot:z" ;;
        gemini|antigravity)
            printf '%s\n' ".gemini:/home/aiuser/.gemini:z" ;;
        claude)
            printf '%s\n' ".claude:/home/aiuser/.claude:z" \
                ".claude.json:/home/aiuser/.claude.json:z" ;;
        opencode)
            printf '%s\n' ".config/opencode:/home/aiuser/.config/opencode:z" \
                ".local/share/opencode:/home/aiuser/.local/share/opencode:z" ;;
        pi)
            printf '%s\n' ".pi:/home/aiuser/.pi:z" ;;
        hermes-agent)
            printf '%s\n' ".hermes:/home/aiuser/.hermes:z" ;;
    esac
}

# Fail unless the file has exactly this content.
# ARGUMENTS:
#   1 - path: file to read
#   2 - content: expected content, without the final newline
_assert_content() {
    [ "$(cat "$1" 2>/dev/null)" = "$2" ] ||
        fail "'$1' holds '$(cat "$1" 2>&1)', expected '$2'"
}

# =========
# Volumes
# ---------

@test "run mounts ~/.agents for every agent" {
    for _a in $AGENTS_ALL hermes-agent; do
        _run_agent "$_a"
        assert_success
        _agent_volumes | grep -Fxq ".agents:/home/aiuser/.agents:z" ||
            fail "no .agents mount for $_a"$'\n'"$(_run_log)"
    done
}

@test "run mounts the config of each agent and nothing else" {
    for _a in $AGENTS_ALL hermes-agent; do
        _run_agent "$_a"
        assert_success
        _want="$(printf '%s\n' ".agents:/home/aiuser/.agents:z" \
            "$(_expected_volumes "$_a")" | sort)"
        [ "$(_agent_volumes)" = "$_want" ] ||
            fail "volumes of $_a:"$'\n'"$(_agent_volumes)"
    done
}

@test "run mounts the config of several agents together" {
    _run_agent claude pi
    assert_success
    _want="$(printf '%s\n' ".agents:/home/aiuser/.agents:z" \
        "$(_expected_volumes claude)" "$(_expected_volumes pi)" | sort)"
    [ "$(_agent_volumes)" = "$_want" ]
}

@test "run mounts .gemini once for gemini and antigravity together" {
    _run_agent gemini antigravity
    assert_success
    [ "$(_agent_volumes | grep -c '^\.gemini:')" -eq 1 ]
}

@test "run does not mount the files of the agents that are not selected" {
    _seed_host
    _run_agent claude
    assert_success
    [ "$(ls -A "$MNT" | sort | tr '\n' ' ')" = ".agents .claude .claude.json " ]
    _run_agent pi
    assert_success
    [ ! -e "$MNT/.copilot" ]
    [ ! -e "$MNT/.gemini" ]
}

@test "every mount of the agents has the z label and none is read-only" {
    _run_agent $AGENTS_ALL
    assert_success
    _n=0
    while read -r _v; do
        _n=$((_n + 1))
        case "$_v" in
            *:z) ;;
            *) fail "volume without the z label: $_v" ;;
        esac
    done < <(run_opt_values --volume)
    [ "$_n" -gt 5 ]
    refute_run_opt_match --volume ':ro'
}

@test "only the Google ADC file is mounted read-only" {
    _host "$XDG_CONFIG_HOME/gcloud/application_default_credentials.json" adc
    _host "$XDG_CONFIG_HOME/gcloud/credentials.db" other
    GCLOUD_REGION=global _run_agent $AGENTS_ALL --gcloud-project my-project
    assert_success
    [ "$(run_opt_values --volume | grep -c ':ro')" -eq 1 ]
    _adc="$XDG_CONFIG_HOME/gcloud/application_default_credentials.json"
    _dst="/home/aiuser/.config/gcloud/application_default_credentials.json"
    assert_run_opt --volume "$_adc:$_dst:ro,z"
    refute_run_mount_of "$XDG_CONFIG_HOME/gcloud"
    refute_run_mount_of "$XDG_CONFIG_HOME/gcloud/credentials.db"
}

# =============
# Host files
# -------------

@test "run copies the host config of every agent in the cache" {
    _seed_host
    _run_agent $AGENTS_ALL
    assert_success
    _assert_content "$MNT/.agents/skills/mine/SKILL.md" agents
    _assert_content "$MNT/.config/gh/hosts.yml" gh
    _assert_content "$MNT/.copilot/config.json" copilot
    _assert_content "$MNT/.gemini/settings.json" gemini
    _assert_content "$MNT/.claude/settings.json" claude
    _assert_content "$MNT/.claude.json" claude-json
    _assert_content "$MNT/.config/opencode/opencode.json" opencode-config
    _assert_content "$MNT/.local/share/opencode/auth.json" opencode-data
    _assert_content "$MNT/.pi/settings.json" pi
}

@test "run copies the host config of hermes-agent" {
    _seed_host
    _run_agent hermes-agent
    assert_success
    _assert_content "$MNT/.hermes/config.yaml" hermes
}

@test "run copies the config of antigravity in the .gemini directory" {
    _seed_host
    _run_agent antigravity
    assert_success
    _assert_content "$MNT/.gemini/settings.json" gemini
}

@test "run never overwrites the config already in the cache" {
    _host "$HOME/.claude/settings.json" host-v1
    _run_agent claude
    assert_success
    _assert_content "$MNT/.claude/settings.json" host-v1
    # The agent changes its config, the host one changes too
    printf 'mine\n' > "$MNT/.claude/settings.json"
    _host "$HOME/.claude/settings.json" host-v2
    _host "$HOME/.claude/new.json" new
    _run_agent claude
    assert_success
    _assert_content "$MNT/.claude/settings.json" mine
    # a new host file waits for --reset-agent-config
    [ ! -e "$MNT/.claude/new.json" ]
}

@test "run does not fail when the host has no config" {
    _run_agent $AGENTS_ALL hermes-agent
    assert_success
    refute_output --partial "did not copy"
    for _d in .agents .claude .copilot .gemini .pi .hermes .config/gh \
        .config/opencode .local/share/opencode; do
        [ -d "$MNT/$_d" ] || fail "missing directory $_d"
    done
    # podman needs a file to mount
    [ -f "$MNT/.claude.json" ]
}

@test "run says when the host config is newer than the copy" {
    # The birth time of the copy is needed
    [ "$(file_btime "$BATS_TEST_TMPDIR")" != 0 ] ||
        skip "the filesystem has no birth time"
    _host "$HOME/.claude/settings.json" v1
    _run_agent claude
    assert_success
    _future_ts="$(
        _t=$(( $(date +%s) + 3600 ))
        date -d "@${_t}" +%Y%m%d%H%M.%S 2>/dev/null ||
            date -r "${_t}" +%Y%m%d%H%M.%S
    )"
    touch -t "${_future_ts}" "$HOME/.claude"
    _run_agent claude -vv
    assert_success
    assert_output --partial "is newer than"
    assert_output --partial "--reset-agent-config"
}

@test "run does not say the host config is newer when it is older" {
    _host "$HOME/.claude/settings.json" v1
    touch -t "2000-01-01" "$HOME/.claude"
    _run_agent claude
    assert_success
    _run_agent claude -vv
    assert_success
    refute_output --partial "is newer than"
}

@test "run --reset-agent-config copies the host config again" {
    _host "$HOME/.claude/settings.json" host-v1
    _run_agent claude
    printf 'mine\n' > "$MNT/.claude/settings.json"
    _host "$HOME/.claude/settings.json" host-v2
    _host "$HOME/.claude/new.json" new
    _run_agent claude --reset-agent-config
    assert_success
    _assert_content "$MNT/.claude/settings.json" host-v2
    _assert_content "$MNT/.claude/new.json" new
}

# ================
# XDG directories
# ----------------

@test "run reads the host config in XDG_CONFIG_HOME and XDG_DATA_HOME" {
    _host "$XDG_CONFIG_HOME/gh/hosts.yml" xdg-gh
    _host "$XDG_CONFIG_HOME/opencode/opencode.json" xdg-config
    _host "$XDG_DATA_HOME/opencode/auth.json" xdg-data
    # What the default locations hold must not be used
    _host "$HOME/.config/gh/hosts.yml" decoy
    _host "$HOME/.config/opencode/opencode.json" decoy
    _host "$HOME/.local/share/opencode/auth.json" decoy
    _run_agent copilot opencode
    assert_success
    _assert_content "$MNT/.config/gh/hosts.yml" xdg-gh
    _assert_content "$MNT/.config/opencode/opencode.json" xdg-config
    _assert_content "$MNT/.local/share/opencode/auth.json" xdg-data
}

@test "run reads ~/.config and ~/.local/share without the XDG variables" {
    _host "$HOME/.config/gh/hosts.yml" home-gh
    _host "$HOME/.config/opencode/opencode.json" home-config
    _host "$HOME/.local/share/opencode/auth.json" home-data
    _host "$XDG_CONFIG_HOME/gh/hosts.yml" decoy
    run env -u XDG_CONFIG_HOME -u XDG_DATA_HOME "$BIN_TEST" run --no-microvm \
        --workspace "$WS" copilot opencode
    assert_success
    _assert_content "$MNT/.config/gh/hosts.yml" home-gh
    _assert_content "$MNT/.config/opencode/opencode.json" home-config
    _assert_content "$MNT/.local/share/opencode/auth.json" home-data
}

# ==============
# Skel of image
# --------------

@test "run seeds the skel files of the agent from the image" {
    _run_agent claude
    assert_success
    _src="$PROJECT_ROOT/image/agents/claude/agents/backport-patch-packager.md"
    [ -f "$_src" ]
    cmp "$_src" "$MNT/.claude/agents/backport-patch-packager.md"
}

@test "run never overwrites a file of the agent with its skel" {
    _host "$HOME/.claude/agents/backport-patch-packager.md" my-own-agent
    _run_agent claude
    assert_success
    _assert_content "$MNT/.claude/agents/backport-patch-packager.md" \
        my-own-agent
    # nor the one changed by the user in the cache
    printf 'edited\n' > "$MNT/.claude/agents/backport-patch-packager.md"
    _run_agent claude
    assert_success
    _assert_content "$MNT/.claude/agents/backport-patch-packager.md" edited
}

# ====================
# Links and rights
# --------------------

@test "run does not follow the links inside the host config" {
    mkdir -p "$HOME/secret"
    printf 'TOPSECRET\n' > "$HOME/secret/key.txt"
    _host "$HOME/.claude/settings.json" ok
    ln -s "$HOME/secret/key.txt" "$HOME/.claude/link-file"
    ln -s "$HOME/secret" "$HOME/.claude/link-dir"
    _run_agent claude
    assert_success
    _assert_content "$MNT/.claude/settings.json" ok
    # grep -r does not follow the links: the content must not be in the cache
    ! grep -rq TOPSECRET "$MNT"
    [ ! -f "$MNT/.claude/link-file" ] || [ -L "$MNT/.claude/link-file" ]
    [ ! -d "$MNT/.claude/link-dir" ] || [ -L "$MNT/.claude/link-dir" ]
}

@test "run copies a host config that is a link to a dotfiles directory" {
    _host "$HOME/dotfiles/claude/settings.json" dotfile
    _host "$HOME/dotfiles/claude.json" dotfile-json
    ln -s "$HOME/dotfiles/claude" "$HOME/.claude"
    ln -s "$HOME/dotfiles/claude.json" "$HOME/.claude.json"
    _run_agent claude
    assert_success
    _assert_content "$MNT/.claude/settings.json" dotfile
    _assert_content "$MNT/.claude.json" dotfile-json
}

@test "run keeps the rights of the copied credentials" {
    _host "$HOME/.claude.json" claude-json
    _host "$HOME/.claude/.credentials.json" secret
    _host "$HOME/.claude/shared.json" shared
    chmod 600 "$HOME/.claude.json" "$HOME/.claude/.credentials.json"
    chmod 640 "$HOME/.claude/shared.json"
    _run_agent claude
    assert_success
    [ "$(file_mode "$MNT/.claude.json")" = 600 ]
    [ "$(file_mode "$MNT/.claude/.credentials.json")" = 600 ]
    [ "$(file_mode "$MNT/.claude/shared.json")" = 640 ]
}
