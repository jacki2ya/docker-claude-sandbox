#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${CLAUDE_SANDBOX_IMAGE:-claude-sandbox:latest}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local/bin}"
LINK_TARGET="$INSTALL_PREFIX/claude-sandbox"
LAUNCHER_SRC="$SCRIPT_DIR/bin/claude-sandbox"

echo "==> Building image: $IMAGE"
docker build -t "$IMAGE" "$SCRIPT_DIR"

echo ""
echo "==> Installing launcher symlink: $LINK_TARGET -> $LAUNCHER_SRC"
if [ ! -w "$INSTALL_PREFIX" ]; then
    SUDO="sudo"
else
    SUDO=""
fi

if [ -L "$LINK_TARGET" ] || [ -e "$LINK_TARGET" ]; then
    echo "    Existing entry found at $LINK_TARGET — replacing"
    $SUDO rm -f "$LINK_TARGET"
fi
$SUDO ln -s "$LAUNCHER_SRC" "$LINK_TARGET"

echo ""
echo "==> Done."
echo ""
if [ ! -f "$HOME/.claude-sandbox/oauth-token" ]; then
    cat <<'EOF'
Next steps (first-time setup):

  1. Generate a long-lived OAuth token on the host:
       claude setup-token

  2. Save it where the launcher will find it:
       mkdir -p ~/.claude-sandbox && chmod 700 ~/.claude-sandbox
       printf '%s' 'PASTE_TOKEN' > ~/.claude-sandbox/oauth-token
       chmod 600 ~/.claude-sandbox/oauth-token

  3. cd into any project and run:
       claude-sandbox
EOF
else
    echo "OAuth token already present at ~/.claude-sandbox/oauth-token — you're good to go."
    echo "  cd into a project and run: claude-sandbox"
fi
