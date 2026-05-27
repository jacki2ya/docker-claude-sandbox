#!/usr/bin/env bash
# End-to-end test for claude-sandbox.
#
# Validates that the built image plus the launcher together produce an isolated
# container where Claude Code can run with --dangerously-skip-permissions, auth
# works, and the host filesystem is not exposed beyond the mounted workspace.
#
# Prerequisites:
#   - Docker running
#   - Image built (run ./install.sh, or `docker build -t claude-sandbox .`)
#   - OAuth token saved at $CLAUDE_SANDBOX_TOKEN_FILE
#     (default: ~/.claude-sandbox/oauth-token)
#
# Usage:
#   ./test.sh              # run all checks (last check makes a live API call)
#   SKIP_AUTH=1 ./test.sh  # skip the live API call

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$SCRIPT_DIR/bin/claude-sandbox"
IMAGE="${CLAUDE_SANDBOX_IMAGE:-claude-sandbox:latest}"
TOKEN_FILE="${CLAUDE_SANDBOX_TOKEN_FILE:-$HOME/.claude-sandbox/oauth-token}"
SKIP_AUTH="${SKIP_AUTH:-0}"

PASS=0
FAIL=0

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; BOLD=""; RESET=""
fi

pass()    { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail()    { printf '  %sFAIL%s  %s\n        %s\n' "$RED" "$RESET" "$1" "$2"; FAIL=$((FAIL+1)); }
section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }

# ----- prerequisites -----
section "Prerequisites"

if command -v docker >/dev/null 2>&1; then
    pass "docker present on PATH"
else
    fail "docker present on PATH" "install Docker Desktop and retry"
    exit 1
fi

if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    pass "image '$IMAGE' is built"
else
    fail "image '$IMAGE' built" "run ./install.sh or: docker build -t $IMAGE ."
    exit 1
fi

if [ -x "$LAUNCHER" ]; then
    pass "launcher exists and is executable"
else
    fail "launcher executable" "missing or not +x: $LAUNCHER"
    exit 1
fi

if [ -s "$TOKEN_FILE" ]; then
    pass "OAuth token file present and non-empty ($TOKEN_FILE)"
else
    fail "OAuth token file" "expected non-empty file at $TOKEN_FILE (see README)"
    exit 1
fi

# ----- workspace setup -----
TEST_DIR="$(mktemp -d -t claude-sandbox-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
SENTINEL_CONTENT="host-created-sentinel-$$"
printf '%s\n' "$SENTINEL_CONTENT" > "$TEST_DIR/sentinel.txt"

# ----- launcher behaviour -----
section "Launcher"

if "$LAUNCHER" --help >/dev/null 2>&1; then
    pass "claude-sandbox --help exits cleanly"
else
    fail "claude-sandbox --help" "expected exit 0"
fi

if "$LAUNCHER" /no/such/path -- true >/dev/null 2>&1; then
    fail "launcher rejects non-existent PROJECT_DIR" "expected non-zero exit"
else
    pass "launcher rejects non-existent PROJECT_DIR"
fi

# ----- entrypoint guard -----
section "Entrypoint guards"

if docker run --rm -i "$IMAGE" >/dev/null 2>&1; then
    fail "entrypoint refuses without OAuth token" "expected non-zero exit"
else
    pass "entrypoint refuses without OAuth token"
fi

# ----- in-container checks (via launcher passthrough) -----
section "Container environment"

CONTAINER_OUT="$("$LAUNCHER" "$TEST_DIR" -- bash -c '
    echo "WHOAMI=$(whoami)"
    echo "UID=$(id -u)"
    echo "TOKEN_PRESENT=$([ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo yes || echo no)"
    echo "GIT_AUTHOR_NAME_SET=$([ -n "${GIT_AUTHOR_NAME:-}" ] && echo yes || echo no)"
    echo "GIT_AUTHOR_EMAIL_SET=$([ -n "${GIT_AUTHOR_EMAIL:-}" ] && echo yes || echo no)"
    echo "DISABLE_AUTOUPDATER=${DISABLE_AUTOUPDATER:-unset}"
    echo "CLAUDE_TELEMETRY_OFF=${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-unset}"
    echo "WORKSPACE_SENTINEL=$(cat /workspace/sentinel.txt 2>/dev/null || echo missing)"
    echo "container-write" > /workspace/from-container.txt 2>/dev/null
    echo "WORKSPACE_WRITE=$([ -f /workspace/from-container.txt ] && echo ok || echo failed)"
    echo "HOST_USERS_VISIBLE=$([ -d /Users ] && echo yes || echo no)"
    echo "CLAUDE_BIN=$(command -v claude || echo missing)"
    echo "SUDO_NOPASSWD=$(sudo -n true 2>/dev/null && echo yes || echo no)"
' 2>&1)" || true

check_kv() {
    local label="$1" expected="$2"
    local actual
    actual="$(printf '%s\n' "$CONTAINER_OUT" | grep -E "^${label}=" | head -1 | cut -d= -f2-)"
    if [ "$actual" = "$expected" ]; then
        pass "$label = $expected"
    else
        fail "$label" "expected '$expected', got '$actual'"
    fi
}

check_kv WHOAMI claude
check_kv UID 1000
check_kv TOKEN_PRESENT yes
check_kv GIT_AUTHOR_NAME_SET yes
check_kv GIT_AUTHOR_EMAIL_SET yes
check_kv DISABLE_AUTOUPDATER 1
check_kv CLAUDE_TELEMETRY_OFF 1
check_kv WORKSPACE_SENTINEL "$SENTINEL_CONTENT"
check_kv WORKSPACE_WRITE ok
check_kv HOST_USERS_VISIBLE no
check_kv SUDO_NOPASSWD yes

CLAUDE_BIN="$(printf '%s\n' "$CONTAINER_OUT" | grep -E '^CLAUDE_BIN=' | head -1 | cut -d= -f2-)"
if [ -n "$CLAUDE_BIN" ] && [ "$CLAUDE_BIN" != "missing" ]; then
    pass "claude binary on PATH ($CLAUDE_BIN)"
else
    fail "claude binary on PATH" "got '$CLAUDE_BIN'"
fi

# ----- round-trip -----
section "Round-trip to host"

if [ -f "$TEST_DIR/from-container.txt" ]; then
    pass "file written inside container is visible on host"
else
    fail "container write round-trip" "expected $TEST_DIR/from-container.txt"
fi

# ----- live auth check -----
section "Auth (live API call)"

if [ "$SKIP_AUTH" = "1" ]; then
    printf '  SKIP  live API call (SKIP_AUTH=1)\n'
else
    # Random nonce defeats any caching and rules out coincidental matches.
    NONCE="claude-sandbox-auth-check-$(date +%s)-$$-$RANDOM"
    AUTH_OUT="$("$LAUNCHER" "$TEST_DIR" -- claude --dangerously-skip-permissions -p "Reply with exactly this token and nothing else: $NONCE" 2>&1)"
    AUTH_EXIT=$?
    if [ "$AUTH_EXIT" -eq 0 ] && printf '%s\n' "$AUTH_OUT" | grep -qF "$NONCE"; then
        pass "OAuth token authenticates; Claude echoed nonce ($NONCE)"
    else
        fail "OAuth auth" "exit=$AUTH_EXIT, nonce='$NONCE' not echoed. raw output: $AUTH_OUT"
    fi
fi

# ----- summary -----
printf '\n'
if [ "$FAIL" -eq 0 ]; then
    printf '%s== %d passed, 0 failed ==%s\n' "$GREEN" "$PASS" "$RESET"
    exit 0
else
    printf '%s== %d passed, %d failed ==%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    exit 1
fi
