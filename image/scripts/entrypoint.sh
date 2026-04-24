#!/bin/sh

SKEL_D="/usr/share/ai-sandbox"

# ── Home provisioning (first-run or after clean) ─────────────────────────────
# Files are copied only if they do not already exist (cp -n).
# This allows users to customise their home without losing changes on restart.

mkdir -p \
    "$HOME/workspace" \
    "$HOME/.copilot/agents"

cp -n "$SKEL_D/skel/.gitconfig" "$HOME/.gitconfig" 2>/dev/null || true

for agent in "$SKEL_D/agents/copilot/"*.md; do
    cp -n "$agent" "$HOME/.copilot/agents/" 2>/dev/null || true
done

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

cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║         AI Agents Sandbox v0.1 — Secure Mode                 ║
╠══════════════════════════════════════════════════════════════╣
║  Available agents :                                          ║
║    • gh copilot   → GitHub Copilot CLI                       ║
║    • gemini       → Gemini CLI                               ║
║    • claude       → Claude Code                              ║
║                                                              ║
║  Directory :                                                 ║
║    ~           → Home, config                                ║
║    ~/workspace → all projects, git clones                    ║
╚══════════════════════════════════════════════════════════════╝
EOF

echo ""
echo "── Authentication status ───────────────────────────────"

check_auth "GitHub (gh)" \
    "gh auth status" \
    "gh auth login --scopes 'copilot'"

echo "  ✅ GitHub Copilot : built-in (gh copilot suggest / explain)"

check_auth "Gemini CLI" \
    "test -f $HOME/.gemini/credentials.json" \
    "gemini auth login"

check_auth "Claude Code" \
    "claude auth status" \
    "claude auth login  (or: export ANTHROPIC_API_KEY=sk-...)"


echo "────────────────────────────────────────────────────────"
echo ""
echo "── Notes ───────────────────────────────────────────────"
echo " To install though Vertex Ai, connect to Google Cloud with: "
echo "  gcloud auth application-default login"
echo "────────────────────────────────────────────────────────"
echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Session started — UID=$(id -u) | $(uname -n)"
echo ""

exec "$@"
