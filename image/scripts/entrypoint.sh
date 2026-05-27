#!/bin/sh

SKEL_D="/usr/share/ai-sandbox"
AGENT="${AGENT:-claude copilot gemini opencode}"

# Return 0 if agent is enabled, 1 otherwise
agent_enabled() {
    case " $AGENT " in
        *" $1 "*)   return 0 ;;
        *)          return 1 ;;
    esac
}

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

# ── Home provisioning (first-run or after clean) ─────────────────────────────
# Files are copied only if they do not already exist (cp -n).
# This allows users to customise their home without losing changes on restart.

mkdir -p \
    "$HOME/workspace" \
    "$HOME/.config/opencode" \
    "$HOME/.copilot/agents"

cp -n "$SKEL_D/skel/.gitconfig" "$HOME/.gitconfig" 2>/dev/null || true

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

agent_enabled "claude"  && provision_agents "claude"  "$HOME/.claude/agents"
agent_enabled "copilot" && provision_agents "copilot" "$HOME/.copilot/agents"
agent_enabled "gemini"  && provision_agents "gemini"  "$HOME/.gemini/agents"

# ─────────────────────────────────────────────────────────────────────────────

_vertex_adc_default="$HOME/.config/gcloud/application_default_credentials.json"
export VERTEX_LOCATION="${VERTEX_LOCATION:-global}"

if [ -z "$GOOGLE_CLOUD_PROJECT" ] && command -v gcloud > /dev/null 2>&1; then
    _project="$(gcloud config get-value project 2>/dev/null)"
    if [ -n "$_project" ] && [ "$_project" != "(unset)" ]; then
        export GOOGLE_CLOUD_PROJECT="$_project"
    fi
fi

# Check authentication status
check_auth() {
    _tool=$1
    _check_cmd=$2
    _hint=$3
    if eval "$_check_cmd" > /dev/null 2>&1; then
        echo "  ✅ $_tool : authenticated"
    else
        echo "  ⚠️  $_tool : not authenticated — run : $_hint"
    fi
}

echo ""
neofetch

# Build banner  lines for active agents
agent_lines=""
agent_enabled "copilot"  && agent_lines="${agent_lines}║    • gh copilot   → GitHub Copilot CLI                       ║\n"
agent_enabled "gemini"   && agent_lines="${agent_lines}║    • gemini       → Gemini CLI                               ║\n"
agent_enabled "claude"   && agent_lines="${agent_lines}║    • claude       → Claude Code                              ║\n"
agent_enabled "opencode" && agent_lines="${agent_lines}║    • opencode     → Open Code                                ║\n"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         AI Agents Sandbox v0.9.0 — Secure Mode               ║" 
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Available agents :                                          ║"
printf "%s" "$agent_lines"
echo "║                                                              ║"
echo "║  Directory :                                                 ║"
echo "║    ~           → Home, config                                ║"
echo "║    ~/workspace → all projects, git clones                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"

echo ""
echo "── Authentication status ───────────────────────────────"

if agent_enabled "copilot"; then
    check_auth "GitHub (gh)" \
        "gh auth status" \
        "gh auth login --scopes 'copilot'"
fi

if agent_enabled "gemini"; then
    check_auth "Gemini CLI" \
        "test -f $HOME/.gemini/credentials.json" \
        "gemini auth login"
fi

if agent_enabled "claude"; then
    check_auth "Claude Code" \
        "claude auth status" \
        "claude auth login  (or: export ANTHROPIC_API_KEY=sk-...)"
fi

echo "────────────────────────────────────────────────────────"
echo ""

if agent_enabled "claude"; then
    echo "── Notes ───────────────────────────────────────────────"
    echo " To install though Vertex Ai, connect to Google Cloud with: "
    echo "  gcloud auth application-default login"
    echo "────────────────────────────────────────────────────────"
    echo ""
fi

if agent_enabled "gemini"; then
    echo "── Notes ───────────────────────────────────────────────"
    echo " If you used a company plan linked to a google project, you would"
    echo " need to edit the file: ~/.gemini/.env and set:"
    echo "  GOOGLE_CLOUD_PROJECT=company-gemini-code-assist"
    echo "────────────────────────────────────────────────────────"
    echo ""
fi

if agent_enabled "opencode"; then
    echo "── Notes ───────────────────────────────────────────────"
    echo " Authenticate Google Vertex with:"
    echo "  gcloud auth application-default login"
    echo " Required environment variables:"
    echo "  GOOGLE_CLOUD_PROJECT=<project ID>"
    echo "  VERTEX_LOCATION=<vertex location>"
    echo " Keep GOOGLE_APPLICATION_CREDENTIALS unset for ADC default path."
    if [ -z "$GOOGLE_CLOUD_PROJECT" ]; then
        echo " Set GOOGLE_CLOUD_PROJECT to enable Vertex AI provider."
    fi
    echo "────────────────────────────────────────────────────────"
    echo ""
fi


echo "[$(date '+%Y-%m-%d %H:%M:%S')] Session started — UID=$(id -u) | $(uname -n) | agent(s)=${AGENT}"
echo ""

cd "$HOME/workspace" 2>/dev/null || true

exec "$@"

