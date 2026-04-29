#!/bin/sh

SKEL_D="/usr/share/ai-sandbox"
AGENT="${AGENT:-claude copilot gemini}"

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
    cd "$HOME" 2>/dev/null || true
    exec setpriv --reuid="$_uid" --regid="$_guid" --init-groups "$0" "$@"
fi

# ── Home provisioning (first-run or after clean) ─────────────────────────────
# Files are copied only if they do not already exist (cp -n).
# This allows users to customise their home without losing changes on restart.

mkdir -p \
    "$HOME/workspace" \
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
agent_enabled "copilot" && agent_lines="${agent_lines}║    • gh copilot   → GitHub Copilot CLI                       ║\n"
agent_enabled "gemini"   && agent_lines="${agent_lines}║    • gemini       → Gemini CLI                               ║\n"
agent_enabled "claude"   && agent_lines="${agent_lines}║    • claude       → Claude Code                              ║\n"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         AI Agents Sandbox v0.1 — Secure Mode                 ║" 
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Available agents :                                          ║"
printf "$agent_lines"
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
    echo "  ✅ GitHub Copilot : built-in (gh copilot suggest / explain)"
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

if agent_enabled "claude" || agent_enabled "gemini"; then
    echo "── Notes ───────────────────────────────────────────────"
    echo " To install though Vertex Ai, connect to Google Cloud with: "
    echo "  gcloud auth application-default login"
    echo "────────────────────────────────────────────────────────"
    echo ""
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Session started — UID=$(id -u) | $(uname -n) | agent(s)=${AGENT}"
echo ""

exec "$@"
