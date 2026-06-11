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

SKEL_D="/usr/share/ai-sandbox"
# Default agent list (contains both trusted and untrusted agents)
# filtering happens in ai-agents-sandbox.sh script
AGENT="${AGENT:-claude copilot gemini opencode antigravity hermes-agent}"
VERSION="${AI_SANDBOX_VERSION:-0.0.0}"
BANNER_HEADLINE="AI AGENTS SANDBOX - $VERSION"

# ==================
# Internal functions
# ------------------

# Provision sub-agents for each relevant agent
provision_agents() {
    _agent_name="$1"
    _target_dir="$2"
    _src_dir="$SKEL_D/agents/${_agent_name}"
    if [ -d "$_src_dir" ]; then
        mkdir -p "$_target_dir"
        for f in "$_src_dir"/*; do
            if [ -f "$f" ]; then
                cp -n "$f" "$_target_dir/" 2>/dev/null || true
            fi
        done
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
    exec setpriv --reuid="$_uid" --regid="$_guid" --init-groups "$0" "$@"
fi

# Home provisioning (first-run or after clean)
# Files are copied only if they do not already exist (cp -n).
# This allows users to customise their home without losing changes on restart.
mkdir -p \
    "$HOME/workspace" \
    "$HOME/.copilot/agents"

cp -n "$SKEL_D/skel/.gitconfig" "$HOME/.gitconfig" 2>/dev/null || true

# Per-agent provisioning
agent_enabled "claude"  && provision_agents "claude"  "$HOME/.claude/agents"
agent_enabled "copilot" && provision_agents "copilot" "$HOME/.copilot/agents"
agent_enabled "gemini"  && provision_agents "gemini"  "$HOME/.gemini/agents"
agent_enabled "antigravity" &&\
    provision_agents "antigravity" "$HOME/.gemini/antigravity-cli"
agent_enabled "opencode" &&\
    mkdir -p "$HOME/.config/opencode" &&\
    provision_agents "opencode" "$HOME/.config/opencode"

# Print the banner with agent status and authentication hints
banner_header

# For each agent, check authentication status and print
agent_enabled "copilot" &&\
    banner_agent "GitHub Copilot CLI" "gh auth status" \
        "gh auth login --scopes 'copilot'"

agent_enabled "gemini" &&\
    banner_agent "Gemini CLI" "test -f $HOME/.gemini/credentials.json" \
        "gemini auth login" &&\
    banner_notes \
        "If you used a company plan linked to a google project, you would" \
        "need to edit the file: ~/.gemini/.env and set:" \
        "GOOGLE_CLOUD_PROJECT=company-gemini-code-assist"

agent_enabled "claude" &&\
    banner_agent "Claude Code" \
        "claude auth status" \
        "claude auth login  (or: export ANTHROPIC_API_KEY=sk-...)" &&\
    banner_notes \
        "To install though Vertex Ai, connect to Google Cloud with:" \
        "gcloud auth application-default login"

agent_enabled "opencode" &&\
    banner_agent "Open Code" \
        "test -f $HOME/.config/opencode/credentials.json" \
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
