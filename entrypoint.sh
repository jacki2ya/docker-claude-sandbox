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

# Docker creates bind-mount parent dirs (~/.claude, ~/.claude/projects) as
# root at container-creation time. Reclaim ownership non-recursively so the
# claude user can write siblings like settings.json next to the mounted
# projects/-workspace leaf. Never touches the mount target itself.
for d in "$HOME/.claude" "$HOME/.claude/projects"; do
    if [ -d "$d" ] && [ "$(stat -c %u "$d" 2>/dev/null)" != "$(id -u)" ]; then
        sudo chown "$(id -u):$(id -g)" "$d"
    fi
done

if [ ! -f "$HOME/.claude.json" ]; then
    cat > "$HOME/.claude.json" <<'JSON'
{
  "hasCompletedOnboarding": true,
  "numStartups": 1
}
JSON
fi

# If a GitHub PAT was passed in, wire it into git for github.com only and
# auto-rewrite SSH-form URLs to HTTPS so existing git@github.com / ssh://
# remotes and terraform `git::ssh://git@github.com/...` modules Just Work.
# The credential helper reads $GITHUB_TOKEN at request time, so the token
# never lands on disk inside the container.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    git config --global credential.https://github.com.helper \
        '!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; }; f'
    git config --global --add url.https://github.com/.insteadOf git@github.com:
    git config --global --add url.https://github.com/.insteadOf ssh://git@github.com/
fi

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

MODEL="${CLAUDE_SANDBOX_MODEL:-claude-opus-4-8}"

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
