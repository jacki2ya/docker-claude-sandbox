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

MODEL="${CLAUDE_SANDBOX_MODEL:-claude-opus-4-7}"

if [ -z "$MODEL" ]; then
    exec claude --dangerously-skip-permissions
fi

# Try the preferred model; if it exits quickly with a non-zero code (e.g. the model
# was retired), fall back to Claude's current default rather than hard-failing.
START_TIME=$(date +%s)
claude --dangerously-skip-permissions --model "$MODEL" || {
    EXIT_CODE=$?
    DURATION=$(( $(date +%s) - START_TIME ))
    # 130 = SIGINT (Ctrl-C): user quit intentionally, don't retry.
    # >10s: real session that ended badly, don't retry.
    if [ "$EXIT_CODE" -ne 130 ] && [ "$DURATION" -lt 10 ]; then
        echo "WARN: claude exited ($EXIT_CODE) within ${DURATION}s using model '$MODEL' — model may be unavailable; retrying with default model" >&2
        exec claude --dangerously-skip-permissions
    fi
    exit "$EXIT_CODE"
}
