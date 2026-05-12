#!/usr/bin/env bash
# Build + run agent-notch against a local mock backend.
#
# One-shot recipe for a fresh checkout: spawns the Python mock
# backend in the background, builds the SwiftPM target in debug
# mode, and exec's the binary. Ctrl+C tears both down cleanly via a
# trap.
#
# Prerequisites checked at the top:
#   - macOS 14+
#   - Xcode 16.0+ (Swift 6.0) — needed by DynamicNotchKit 1.1.0
#   - python3
#
# Usage:
#
#   ./scripts/test-locale.sh             # default port 3340
#   ./scripts/test-locale.sh --port 4200 # custom port
#
# The script changes the working directory to the repo root before
# building so it can be invoked from anywhere.

set -euo pipefail

PORT=3340
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ─── Locate repo root ───────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "[test-locale] repo root: $REPO_ROOT"

# ─── Prereq checks ──────────────────────────────────────────────────────

if ! command -v swift >/dev/null 2>&1; then
    echo "❌ swift not found. Install Xcode from the App Store, then" >&2
    echo "   run:  xcode-select --install" >&2
    exit 1
fi

SWIFT_VERSION="$(swift --version 2>&1 | head -1)"
echo "[test-locale] $SWIFT_VERSION"

if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ python3 not found. macOS 12+ ships it; install Command Line" >&2
    echo "   Tools with:  xcode-select --install" >&2
    exit 1
fi

# ─── Patch local config so the app talks to our mock ────────────────────

CONFIG_DIR="$HOME/Library/Application Support/agent-notch"
CONFIG_FILE="$CONFIG_DIR/config.json"
mkdir -p "$CONFIG_DIR"

# Back up the user's existing config (if any) before we overwrite it so a
# real installation isn't silently clobbered when someone runs the test
# recipe on a machine that already had agent-notch configured.
if [[ -f "$CONFIG_FILE" ]]; then
    BACKUP_FILE="$CONFIG_FILE.test-locale.backup.$(date +%s)"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    echo "[test-locale] existing config backed up → $BACKUP_FILE"
    # We'll restore it on exit so the previous installation is untouched.
    RESTORE_CONFIG="$BACKUP_FILE"
else
    RESTORE_CONFIG=""
fi

cat >"$CONFIG_FILE" <<EOF
{
  "schemaVersion": 1,
  "backendURL": "http://127.0.0.1:$PORT"
}
EOF
echo "[test-locale] wrote $CONFIG_FILE (backend → http://127.0.0.1:$PORT)"

# ─── Start mock backend ─────────────────────────────────────────────────

MOCK_LOG="$(mktemp -t agent-notch-mock.XXXXXX.log)"
echo "[test-locale] mock backend log: $MOCK_LOG"

python3 "$REPO_ROOT/scripts/mock-backend.py" --port "$PORT" >"$MOCK_LOG" 2>&1 &
MOCK_PID=$!

# The swift-run child is captured in NOTCH_PID; we never use `pkill -f
# agent-notch` because it would also nuke a user-installed
# /Applications/AgentNotch.app currently running in another window.
NOTCH_PID=""

cleanup() {
    echo ""
    echo "[test-locale] cleaning up..."
    if [[ -n "$NOTCH_PID" ]] && kill -0 "$NOTCH_PID" 2>/dev/null; then
        kill "$NOTCH_PID" 2>/dev/null || true
        wait "$NOTCH_PID" 2>/dev/null || true
    fi
    if kill -0 "$MOCK_PID" 2>/dev/null; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    # Restore the user's previous config (if there was one) so we
    # don't leave the mock URL pointing at a dead port.
    if [[ -n "$RESTORE_CONFIG" && -f "$RESTORE_CONFIG" ]]; then
        cp "$RESTORE_CONFIG" "$CONFIG_FILE"
        echo "[test-locale] restored original config from $RESTORE_CONFIG"
    fi
    echo "[test-locale] done."
}
trap cleanup EXIT INT TERM

# Wait up to 3s for the mock to start accepting connections.
for _ in 1 2 3 4 5 6; do
    if curl -fsS "http://127.0.0.1:$PORT/api/local-sessions" >/dev/null 2>&1; then
        echo "[test-locale] mock backend up on :$PORT"
        break
    fi
    sleep 0.5
done

# ─── Build ──────────────────────────────────────────────────────────────

echo "[test-locale] building agent-notch (this is fast after the first run)..."
swift build

# ─── Run ────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────────────────────────"
echo " agent-notch is starting."
echo ""
echo " - Move your mouse to the top centre of the screen to expand"
echo "   the notch HUD."
echo " - The mock backend serves 2 fake sessions + 3 fake todos that"
echo "   should populate the sidebar and the todo strip."
echo " - mock backend log:  $MOCK_LOG"
echo " - press Ctrl+C in THIS terminal to stop everything."
echo "────────────────────────────────────────────────────────────────"
echo ""

# Run as a background child so we can capture its PID — needed for the
# cleanup trap, which must NOT use `pkill -f agent-notch` (that would
# also kill a user-installed /Applications/AgentNotch.app running in
# another window).
swift run agent-notch &
NOTCH_PID=$!
wait "$NOTCH_PID"
