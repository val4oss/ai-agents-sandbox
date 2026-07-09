#!/bin/sh
# entrypoint.sh - Script call as entrypoint of the container.
# Copyright (C) 2026  val4oss <val4oss@pm.me>
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANYWARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# ================
# Global variables
# ----------------
PRJ_ID="ai-agents-sandbox"

SHARE_SKEL_D="/usr/share/$PRJ_ID/skel"
SHARE_AGENTS_D="/usr/share/$PRJ_ID/agents"
# Default agent list (contains both trusted and untrusted agents)
# filtering happens in ai-agents-sandbox.sh script
AGENT="${AGENT:-claude copilot gemini opencode antigravity hermes-agent}"
VERSION="${AI_SANDBOX_VERSION:-0.0.0}"
BANNER_HEADLINE="AI AGENTS SANDBOX - $VERSION"

# ==================
# Internal functions
# ------------------

# Provision setup agents for each relevant agent
setup_agent() {
    _agent_name="$1"
    _target_dir="$2"
    _src_dir="$SHARE_AGENTS_D/${_agent_name}"
    if [ -d "$_src_dir" ]; then
        mkdir -p "$_target_dir"
        cp -rn "$_src_dir"/* "${_target_dir}/" 2>/dev/null || true
    fi
}

# Return 0 if agent is enabled, 1 otherwise
agent_enabled() {
    case " $AGENT " in
        *" $1 "*)   return 0 ;;
        *)          return 1 ;;
    esac
}

# Detect isolation mode based on mount points
get_mode() {
    if mount | grep 'on / type' | grep "virtiofs" > /dev/null 2>&1; then
        echo "MICROVM ISOLATION"
    else
        echo "CONTAINER ISOLATION"
    fi
}

# Check authentication status
check_auth() {
    _check_cmd=$1
    _hint=$2
    if eval "$_check_cmd" > /dev/null 2>&1; then
        echo "✅ authenticated"
    else
        echo "⚠️ not authenticated — run : $_hint"
    fi
}

# Return 0 when Gemini credentials exist in a known persisted path.
gemini_auth_check() {
    [ -f "$HOME/.gemini/oauth_creds.json" ] || \
        [ -f "$HOME/.gemini/credentials.json" ]
}

# Return 0 when Claude has an active login or API key auth.
claude_auth_check() {
    claude auth status > /dev/null 2>&1 || \
        [ -n "${ANTHROPIC_API_KEY:-}" ] || \
        [ -f "$HOME/.config/gcloud/application_default_credentials.json" ] || {
            [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && \
                [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]
        }
}

# Return 0 when OpenCode can use ADC or an explicit credentials path.
opencode_auth_check() {
    [ -f "$HOME/.config/gcloud/application_default_credentials.json" ] || {
        [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && \
            [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]
    }
}

# Print the banner header
banner_header() {
    _mode="$(get_mode)"
    toilet -t -f pagga  -F metal:border "$BANNER_HEADLINE"
    toilet -t -f smbraille "$_mode"
}

# Print the banner for an agent with authentication status
# Parameters:
# 1: agent name
# 2: authentication check command
# 3: authentication hint command
banner_agent() {
    if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
        return
    fi
    _green=$(tput setaf 2)
    _reset=$(tput sgr0)
    _agent_name="$1"
    _auth_cmd="$2"
    _auth_hint="$3"
    _auth_status="$(check_auth   "$_auth_cmd" "$_auth_hint")"
    printf "\t%b• Agent:%b %s\n" "$_green" "$_reset" "$_agent_name"
    printf "\t         %s\n"     "$_auth_status"
}

banner_notes() {
    _blue=$(tput setaf 6)
    _reset=$(tput sgr0)
    printf "\t%b  Notes:%b\n" "$_blue" "$_reset"
    printf "\t         %s\n"  "$@"
}

# ===========
# Entry point
# -----------

# Create the user if not exists, with home and permissions to write in it.
if [ "$(id -u)" = "0" ] && id aiuser >/dev/null 2>&1; then
    _uid="$(id -u aiuser)"
    _guid="$(id -g aiuser)"
    _home="$(getent passwd aiuser | cut -d: -f6)"
    export HOME="$_home"
    export USER="aiuser"
    export LOGNAME="aiuser"
    export TERM="xterm-256color"
    cd "$HOME" 2>/dev/null || true
    exec setpriv --reuid="$_uid" --regid="$_guid" --init-groups \
        --clear-groups --inh-caps=-all "$0" "$@"
fi

# Initial setup (one-time)
_work_d="$HOME/workspace"
[ -d "$_work_d" ] && mkdir -p "$_work_d"
[ -d "$SHARE_SKEL_D" ] && {
    cp -r "$SHARE_SKEL_D"/* "$HOME"/
    rm -rf "$SHARE_SKEL_D"
}
[ -d "$SHARE_AGENTS_D" ] && {
    agent_enabled "antigravity" &&\
        setup_agent "antigravity" "$HOME/.gemini/config"
    agent_enabled "claude" && setup_agent "claude" "$HOME/.claude"
    agent_enabled "copilot" && setup_agent "copilot" "$HOME/.copilot"
    agent_enabled "gemini" && setup_agent "gemini" "$HOME/.gemini"
    agent_enabled "opencode" && setup_agent "opencode" "$HOME/.config/opencode"
    agent_enabled "hermes-agent" && setup_agent "hermes-agent" "$HOME/.hermes"
    rm -rf "$SHARE_AGENTS_D"
}

# Install sourceable Gemini helper and hook it into .bashrc.
_gemini_helper_src="$HOME/gemini-env.sh"
if agent_enabled "gemini" && [ -f "$_gemini_helper_src" ]; then
    _bashrc="$HOME/.bashrc"
    [ -f "$_bashrc" ] || : > "$_bashrc"
    _gemini_marker="# >>> $PRJ_ID gemini env helper >>>"
    if ! grep -F "$_gemini_marker" "$_bashrc" > /dev/null 2>&1; then
        cat >> "$_bashrc" << 'EOF'

if [ -f "${HOME}/gemini-env.sh" ]; then
    . "${HOME}/gemini-env.sh"
fi
EOF
    fi
fi

# Run all run hooks
find "/usr/local/bin/$PRJ_ID-run-hooks/" !\
    -name "$(printf "*\n*")"\
    -name "*.sh" \
    | sort > tmp
while IFS= read -r _h;
do
    sh "$_h" || exit 1;
done < tmp
rm -f tmp

# Print the banner with agent status and authentication hints
banner_header

# For each agent, check authentication status and print
agent_enabled "copilot" &&\
    banner_agent "GitHub Copilot CLI" "gh auth status" \
        "gh auth login --scopes 'copilot'"

agent_enabled "gemini" &&\
    banner_agent "Gemini CLI" "gemini_auth_check" \
        "gemini auth login" &&\
    banner_notes \
        "If you used a company plan linked to a google project, you would" \
        "need to edit the file: ~/.gemini/.env and set:" \
        "GOOGLE_CLOUD_PROJECT=company-gemini-code-assist"

agent_enabled "claude" &&\
    banner_agent "Claude Code" \
        "claude_auth_check" \
        "claude auth login  (or: export ANTHROPIC_API_KEY=sk-...)" &&\
    banner_notes \
        "To install though Vertex Ai, connect to Google Cloud with:" \
        "gcloud auth application-default login"

agent_enabled "opencode" &&\
    banner_agent "Open Code" \
        "opencode_auth_check" \
        "gcloud auth application-default login" &&\
    banner_notes \
        "Required environment variables:" \
        "GOOGLE_CLOUD_PROJECT=<project ID>" \
        "VERTEX_LOCATION=<vertex location>" \
        "Keep GOOGLE_APPLICATION_CREDENTIALS unset for ADC default path." \
        "Set GOOGLE_CLOUD_PROJECT to enable Vertex AI provider."
agent_enabled "antigravity" &&\
    banner_agent "Antigravity" \
        "test -f $HOME/.gemini/antigravity-cli/antigravity-oauth-token" \
        "agy" &&\
    banner_notes \
        "Only cli is installed: agy" \
        "When you authenticate through Google OAuth, the link provided can" \
        "integrate some spaces, be careful when you copy-paste the URL."
# Print disclaimer note for untrusted Hermes Agent
agent_enabled "hermes-agent" &&\
    banner_agent "Hermes Agent (untrusted)" \
        "test -f \$HOME/.hermes/config.yaml" \
        "hermes setup" &&\
    banner_notes \
        "Config lives at ~/.hermes/config.yaml" \
        "Run 'hermes setup' or 'hermes model' to configure provider/keys."

echo ""

cd "$HOME/workspace" 2>/dev/null || true

exec "$@"
