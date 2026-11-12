#!/usr/bin/env bash
set -euo pipefail

# Development only (M3). Lets the current user run exactly two commands as
# root without a password, for the debug-build dev backend
# (STAYAWAKE_BACKEND=sudoers):
#
#   /usr/bin/pmset -a disablesleep 0
#   /usr/bin/pmset -a disablesleep 1
#
# Nothing else. No wildcards, no other arguments, no other users.
# The rule is validated with visudo on a temp file before it is installed.
#
# Usage:
#   ./scripts/dev-sudoers.sh            install (asks for your password once)
#   ./scripts/dev-sudoers.sh --remove   remove the rule again
#   ./scripts/dev-sudoers.sh --print    show the rule, change nothing
#
# The rule is replaced by the root helper in M5. Remove it before then if
# you stop developing: while it exists, any process running as you can turn
# sleep off for the whole Mac.

TARGET="/etc/sudoers.d/stayawake-dev"
USER_NAME="$(id -un)"

if [[ "$USER_NAME" == "root" || -z "$USER_NAME" ]]; then
    echo "✗ Run this as your normal user, not as root." >&2
    exit 1
fi
if [[ ! "$USER_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "✗ Unexpected characters in the user name: $USER_NAME" >&2
    exit 1
fi

RULE_OFF="$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0"
RULE_ON="$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1"
CONTENT="# StayAwake development backend. Remove with scripts/dev-sudoers.sh --remove
$RULE_OFF
$RULE_ON"

case "${1:-}" in
    --print)
        echo "$CONTENT"
        exit 0
        ;;
    --remove)
        sudo rm -f "$TARGET"
        echo "✓ Removed $TARGET"
        exit 0
        ;;
    "")
        ;;
    *)
        echo "usage: $0 [--remove|--print]" >&2
        exit 64
        ;;
esac

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
echo "$CONTENT" > "$TMP"
chmod 0440 "$TMP"

echo "→ Validating the rule with visudo..."
if ! visudo -c -f "$TMP" >/dev/null; then
    echo "✗ visudo rejected the rule, nothing installed." >&2
    exit 1
fi

echo "→ Installing $TARGET (sudo asks for your password)..."
sudo install -m 0440 -o root -g wheel "$TMP" "$TARGET"

echo "→ Checking the installed file..."
sudo visudo -c -f "$TARGET" >/dev/null
echo "✓ Installed $TARGET"
echo ""
echo "$CONTENT"
echo ""
echo "  Remove later: ./scripts/dev-sudoers.sh --remove"
