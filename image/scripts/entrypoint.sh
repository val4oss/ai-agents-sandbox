#!/bin/bash
set -euo pipefail

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

if [ ! -d "$HOME/venv" ]; then
    echo "[*] Creating Python virtualenv..."
    python3 -m virtualenv "$HOME/venv"
    echo "[✓] Virtualenv ready."
fi


# Check authentication status
check_auth() {
    local tool=$1
    local check_cmd=$2
    local hint=$3
    if eval "$check_cmd" &>/dev/null; then
        echo "  ✅ $tool : authenticated"
    else
        echo "  ⚠️  $tool : not authenticated — run : $hint"
    fi
}

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
║    ~  → all projects, git clones, config (read/write)        ║
╚══════════════════════════════════════════════════════════════╝
EOF

echo ""
echo "── Authentication status ───────────────────────────────"

check_auth "GitHub (gh)" \
    "gh auth status" \
    "gh auth login"

echo "  ✅ GitHub Copilot : built-in (gh copilot suggest / explain)"

check_auth "Gemini CLI" \
    "test -f $HOME/.gemini/credentials.json" \
    "gemini auth login"

check_auth "Claude Code" \
    "test -f $HOME/.claude/credentials.json || test -n \"\${ANTHROPIC_API_KEY:-}\"" \
    "claude auth login  (or: export ANTHROPIC_API_KEY=sk-...)"

echo "────────────────────────────────────────────────────────"
echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Session started — UID=$(id -u) | $(uname -n)"
echo ""

exec "$@"
