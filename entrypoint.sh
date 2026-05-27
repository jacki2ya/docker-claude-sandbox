#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" = "0" ]; then
    echo "ERROR: claude-sandbox must not run as root inside the container." >&2
    echo "       Claude Code refuses --dangerously-skip-permissions when running as root." >&2
    exit 1
fi

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    cat >&2 <<'EOF'
ERROR: CLAUDE_CODE_OAUTH_TOKEN is not set inside the container.

The launcher reads this from a host file (default: ~/.claude-sandbox/oauth-token).
First-time setup on the host:
  1. claude setup-token
  2. mkdir -p ~/.claude-sandbox && chmod 700 ~/.claude-sandbox
  3. printf '%s' 'PASTE_TOKEN' > ~/.claude-sandbox/oauth-token
     chmod 600 ~/.claude-sandbox/oauth-token
EOF
    exit 1
fi

if [ ! -f "$HOME/.claude.json" ]; then
    cat > "$HOME/.claude.json" <<'JSON'
{
  "hasCompletedOnboarding": true,
  "numStartups": 1
}
JSON
fi

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

exec claude --dangerously-skip-permissions
