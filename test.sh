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
# Resolve to physical paths up-front: macOS mktemp returns paths under
# /var/folders/... which symlink to /private/var/folders/..., and the launcher
# uses `pwd -P`, so we need to match.
TEST_DIR="$(cd "$(mktemp -d -t claude-sandbox-test.XXXXXX)" && pwd -P)"
TEST_DIR_2="$(cd "$(mktemp -d -t claude-sandbox-test2.XXXXXX)" && pwd -P)"
TEST_PROJECTS_DIR="$(cd "$(mktemp -d -t claude-sandbox-projects.XXXXXX)" && pwd -P)"
trap 'rm -rf "$TEST_DIR" "$TEST_DIR_2" "$TEST_PROJECTS_DIR"' EXIT

# Point every launcher invocation at an isolated host CC projects dir so this
# run never touches the real ~/.claude/projects.
export CLAUDE_SANDBOX_PROJECTS_DIR="$TEST_PROJECTS_DIR"

SENTINEL_CONTENT="host-created-sentinel-$$"
printf '%s\n' "$SENTINEL_CONTENT" > "$TEST_DIR/sentinel.txt"

# Slug used by Claude Code (and now by the launcher): the absolute path with
# every non-alphanumeric char turned into '-'. Verified empirically against
# every slug in the real ~/.claude/projects/ tree.
host_slug_dir_for() {
    local slug
    slug="$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"
    printf '%s/%s' "$TEST_PROJECTS_DIR" "$slug"
}
SLUG_DIR_1="$(host_slug_dir_for "$TEST_DIR")"
SLUG_DIR_2="$(host_slug_dir_for "$TEST_DIR_2")"

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

TEST_DIR_BASENAME="$(basename "$TEST_DIR")"
# Hostname derivation must match the launcher's HOSTNAME_SAFE logic.
EXPECTED_HOSTNAME="$(printf '%s' "$TEST_DIR_BASENAME" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' \
    | sed -E 's/^-+//; s/-+$//' | cut -c1-63)"
[ -z "$EXPECTED_HOSTNAME" ] && EXPECTED_HOSTNAME="sandbox"

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
    # --- self-awareness baked into the image ---
    # Meaningful hostname (vs random hash) and project-name env var; both come
    # from the launcher. Statusline script + baked settings.json + baked
    # CLAUDE.md come from the Dockerfile.
    echo "HOSTNAME=$(hostname)"
    echo "PROJECT_NAME_ENV=${CLAUDE_SANDBOX_PROJECT_NAME:-unset}"
    echo "STATUSLINE_EXEC=$([ -x /usr/local/bin/claude-statusline ] && echo yes || echo no)"
    echo "STATUSLINE_OUTPUT=$(printf %s "{\"model\":{\"display_name\":\"X\"},\"cwd\":\"/workspace\"}" | /usr/local/bin/claude-statusline 2>/dev/null)"
    echo "BAKED_CLAUDE_MD=$([ -f "$HOME/.claude/CLAUDE.md" ] && echo yes || echo no)"
    echo "BAKED_CLAUDE_MD_OWNER_UID=$(stat -c %u "$HOME/.claude/CLAUDE.md" 2>/dev/null || echo none)"
    echo "BAKED_CLAUDE_MD_MENTIONS_SANDBOX=$(grep -q "claude-sandbox" "$HOME/.claude/CLAUDE.md" 2>/dev/null && echo yes || echo no)"
    # Read baked settings BEFORE the writability test overwrites it.
    echo "BAKED_STATUSLINE_COMMAND=$(jq -r ".statusLine.command // empty" "$HOME/.claude/settings.json" 2>/dev/null)"
    # --- host-config isolation checks ---
    # ~/.claude-sandbox/ on the host holds the OAuth token; must not appear
    # in the container. The full host ~/.claude/projects/ tree must also
    # stay invisible — only the single mounted slug dir should be reachable,
    # surfacing as ~/.claude/projects/-workspace/.
    echo "OAUTH_TOKEN_FILE_LEAKED=$([ -e "$HOME/.claude-sandbox/oauth-token" ] && echo yes || echo no)"
    echo "SANDBOX_DIR_LEAKED=$([ -e "$HOME/.claude-sandbox" ] && echo yes || echo no)"
    echo "PROJECTS_SIBLINGS_VISIBLE=$(ls /home/claude/.claude/projects/ 2>/dev/null | sort | tr "\n" ",")"
    # The bind-mount parent ~/.claude must be writable by claude (ownership
    # guard worked) and not actually be the host ~/.claude.
    echo "CLAUDE_DIR_OWNER_UID=$(stat -c %u "$HOME/.claude" 2>/dev/null || echo none)"
    echo "SETTINGS_WRITE=$(echo "{}" > "$HOME/.claude/settings.json" 2>/dev/null && echo ok || echo failed)"
    # Mount surface: only /workspace and /home/claude/.claude/projects/-workspace
    # should be bind-mounted into the container. Anything else is a leak.
    BIND_MOUNTS="$(awk '"'"'$5 ~ /^\/(workspace|home\/claude\/\.claude)/ {print $5}'"'"' /proc/self/mountinfo | sort -u | tr "\n" "," | sed "s/,$//")"
    echo "BIND_MOUNTS=$BIND_MOUNTS"
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
check_kv HOSTNAME "$EXPECTED_HOSTNAME"
check_kv PROJECT_NAME_ENV "$TEST_DIR_BASENAME"
check_kv STATUSLINE_EXEC yes
check_kv BAKED_CLAUDE_MD yes
check_kv BAKED_CLAUDE_MD_OWNER_UID 1000
check_kv BAKED_CLAUDE_MD_MENTIONS_SANDBOX yes
check_kv BAKED_STATUSLINE_COMMAND /usr/local/bin/claude-statusline
check_kv OAUTH_TOKEN_FILE_LEAKED no
check_kv SANDBOX_DIR_LEAKED no
check_kv PROJECTS_SIBLINGS_VISIBLE "-workspace,"
check_kv CLAUDE_DIR_OWNER_UID 1000
check_kv SETTINGS_WRITE ok
check_kv BIND_MOUNTS "/home/claude/.claude/projects/-workspace,/workspace"

# Statusline output: must start with literal "sandbox" tag and contain the
# project name (basename of TEST_DIR, which is what the launcher passes via
# CLAUDE_SANDBOX_PROJECT_NAME).
STATUSLINE_OUT="$(printf '%s\n' "$CONTAINER_OUT" | grep -E '^STATUSLINE_OUTPUT=' | head -1 | cut -d= -f2-)"
if printf '%s' "$STATUSLINE_OUT" | grep -qE "^sandbox / " && \
   printf '%s' "$STATUSLINE_OUT" | grep -qF "$TEST_DIR_BASENAME"; then
    pass "claude-statusline emits 'sandbox / <project> / …' ($STATUSLINE_OUT)"
else
    fail "claude-statusline output" "expected leading 'sandbox / …' + '$TEST_DIR_BASENAME', got: '$STATUSLINE_OUT'"
fi

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

# ----- persistence: memory + transcripts unify with host's ~/.claude/projects -----
section "Persistence (unified with host CC, per-project)"

PERSIST_NONCE_1="memory-$(date +%s)-$$-A"
PERSIST_NONCE_2="memory-$(date +%s)-$$-B"
INHERIT_NONCE="inherited-from-host-$(date +%s)-$$"

# The headline test: memory pre-existing on the host (placed there as if by a
# prior native `claude` run) must be visible inside the sandbox. This is the
# scenario the homelab bug report described.
mkdir -p "$SLUG_DIR_2/memory"
printf '%s' "$INHERIT_NONCE" > "$SLUG_DIR_2/memory/inherited.md"

INHERIT_OUT="$("$LAUNCHER" "$TEST_DIR_2" -- bash -c '
    cat ~/.claude/projects/-workspace/memory/inherited.md 2>/dev/null
' 2>/dev/null)"
if [ "$INHERIT_OUT" = "$INHERIT_NONCE" ]; then
    pass "sandbox inherits pre-existing host memory for a known project"
else
    fail "inherits host memory" "expected '$INHERIT_NONCE', got '$INHERIT_OUT'"
fi

# Run A in project 1: write a memory file and a fake transcript jsonl.
"$LAUNCHER" "$TEST_DIR" -- bash -c "
    set -e
    mkdir -p ~/.claude/projects/-workspace/memory
    printf '%s' '$PERSIST_NONCE_1' > ~/.claude/projects/-workspace/memory/test-sentinel.md
    printf '%s' '$PERSIST_NONCE_1' > ~/.claude/projects/-workspace/test-transcript.jsonl
" >/dev/null 2>&1
A_RUN1_EXIT=$?

if [ "$A_RUN1_EXIT" -eq 0 ]; then
    pass "run A (write memory + transcript) exited 0"
else
    fail "run A write" "exit=$A_RUN1_EXIT"
fi

HOST_MEM_FILE="$SLUG_DIR_1/memory/test-sentinel.md"
HOST_TR_FILE="$SLUG_DIR_1/test-transcript.jsonl"

if [ -f "$HOST_MEM_FILE" ] && [ "$(cat "$HOST_MEM_FILE")" = "$PERSIST_NONCE_1" ]; then
    pass "memory file landed in the host's project slug dir (writes flow back)"
else
    fail "memory file on host" "expected '$PERSIST_NONCE_1' at $HOST_MEM_FILE; got '$(cat "$HOST_MEM_FILE" 2>/dev/null)'"
fi

if [ -f "$HOST_TR_FILE" ] && [ "$(cat "$HOST_TR_FILE")" = "$PERSIST_NONCE_1" ]; then
    pass "transcript file landed in the host's project slug dir"
else
    fail "transcript file on host" "expected '$PERSIST_NONCE_1' at $HOST_TR_FILE"
fi

# Run B in project 1 (fresh container): the memory file should still be there.
B_RUN_OUT="$("$LAUNCHER" "$TEST_DIR" -- bash -c '
    cat ~/.claude/projects/-workspace/memory/test-sentinel.md 2>/dev/null
    echo
    cat ~/.claude/projects/-workspace/test-transcript.jsonl 2>/dev/null
' 2>/dev/null)"
if printf '%s' "$B_RUN_OUT" | grep -qF "$PERSIST_NONCE_1"; then
    pass "memory survives a fresh container (--continue / --resume ready)"
else
    fail "memory persistence" "expected '$PERSIST_NONCE_1' in output: $B_RUN_OUT"
fi

# Cross-project isolation: project 2's container must see only project 2's
# memory (its own + the pre-existing inherited.md), never project 1's.
"$LAUNCHER" "$TEST_DIR_2" -- bash -c "
    set -e
    mkdir -p ~/.claude/projects/-workspace/memory
    printf '%s' '$PERSIST_NONCE_2' > ~/.claude/projects/-workspace/memory/test-sentinel.md
" >/dev/null 2>&1

if [ "$SLUG_DIR_1" != "$SLUG_DIR_2" ] && \
   [ "$(cat "$SLUG_DIR_2/memory/test-sentinel.md" 2>/dev/null)" = "$PERSIST_NONCE_2" ]; then
    pass "project 2 writes to its own host slug dir, separate from project 1"
else
    fail "project 2 slug separation" "SLUG_DIR_2='$SLUG_DIR_2' (must exist and != '$SLUG_DIR_1')"
fi

P2_VIEW_OUT="$("$LAUNCHER" "$TEST_DIR_2" -- bash -c '
    cat ~/.claude/projects/-workspace/memory/test-sentinel.md 2>/dev/null
' 2>/dev/null)"
if printf '%s' "$P2_VIEW_OUT" | grep -qF "$PERSIST_NONCE_2" && \
   ! printf '%s' "$P2_VIEW_OUT" | grep -qF "$PERSIST_NONCE_1"; then
    pass "project 2 sees only its own memory, not project 1's"
else
    fail "cross-project isolation (P2)" "got: $P2_VIEW_OUT"
fi

P1_VIEW_OUT="$("$LAUNCHER" "$TEST_DIR" -- bash -c '
    cat ~/.claude/projects/-workspace/memory/test-sentinel.md 2>/dev/null
' 2>/dev/null)"
if printf '%s' "$P1_VIEW_OUT" | grep -qF "$PERSIST_NONCE_1" && \
   ! printf '%s' "$P1_VIEW_OUT" | grep -qF "$PERSIST_NONCE_2"; then
    pass "project 1 still sees only its own memory, not project 2's"
else
    fail "cross-project isolation (P1)" "got: $P1_VIEW_OUT"
fi

# Plant an unrelated neighbouring slug dir in the projects root and confirm
# it stays invisible from inside project 1's container.
OTHER_SLUG="-neighbour-deadbeef-must-not-leak"
mkdir -p "$TEST_PROJECTS_DIR/$OTHER_SLUG/memory"
printf 'must-not-leak' > "$TEST_PROJECTS_DIR/$OTHER_SLUG/memory/leak.md"

LEAK_OUT="$("$LAUNCHER" "$TEST_DIR" -- bash -c '
    ls /home/claude/.claude/projects/ 2>/dev/null | sort | tr "\n" ","
' 2>/dev/null)"
if [ "$LEAK_OUT" = "-workspace," ]; then
    pass "neighbouring project slugs not accessible from inside the sandbox"
else
    fail "projects-dir neighbour isolation" "expected only '-workspace,' under ~/.claude/projects/, got: '$LEAK_OUT'"
fi

# Confirm settings.json (written at /home/claude/.claude/settings.json during
# the Container environment probe) did NOT land in the host projects dir —
# i.e. only the leaf slug dir is mounted, not the whole .claude tree.
if [ ! -e "$SLUG_DIR_1/settings.json" ] && \
   [ ! -e "$TEST_PROJECTS_DIR/settings.json" ]; then
    pass "settings.json is NOT persisted to the host projects dir (leaf-mount confirmed)"
else
    fail "leaf-mount" "settings.json leaked into $TEST_PROJECTS_DIR"
fi

# Wipe + re-create: a deleted slug dir should regenerate cleanly. Verify
# host-side (no in-container call, so unrelated stderr can't taint the check).
rm -rf "$SLUG_DIR_1"
"$LAUNCHER" "$TEST_DIR" -- true >/dev/null 2>&1
WIPE_EXIT=$?
if [ "$WIPE_EXIT" -eq 0 ] && [ -d "$SLUG_DIR_1" ] && \
   [ -z "$(ls -A "$SLUG_DIR_1" 2>/dev/null)" ]; then
    pass "wiped slug dir regenerates empty on next run"
else
    fail "slug-dir wipe + regenerate" "exit=$WIPE_EXIT, exists=$( [ -d "$SLUG_DIR_1" ] && echo yes || echo no ), contents='$(ls -A "$SLUG_DIR_1" 2>/dev/null)'"
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
