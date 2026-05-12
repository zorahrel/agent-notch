#!/usr/bin/env bash
# Build a real `AgentNotch.app` bundle ready to drop into /Applications.
#
# `swift build -c release` only produces a plain Mach-O executable in
# `.build/release/agent-notch`. macOS needs a bundle (Info.plist +
# Contents/ directory structure) before:
#
#   - Launchpad / Finder can launch the binary
#   - TCC prompts can attribute Microphone / Speech permissions
#   - codesign / notarytool / Sparkle can sign + ship the artifact
#
# This script wraps the SwiftPM output into that bundle layout. It
# does NOT submit anything to Apple — signing here is ad-hoc so the
# app launches on the build host. A separate `release.sh` flow will
# handle Developer ID signing + notarization when we have a cert.
#
# Usage:
#
#   ./scripts/build-app.sh
#   ./scripts/build-app.sh --output dist/AgentNotch.app
#   ./scripts/build-app.sh --install              # also copy into /Applications
#   ./scripts/build-app.sh --version 0.2.1        # override Info.plist version

set -euo pipefail

# ─── Defaults ───────────────────────────────────────────────────────────

OUTPUT="dist/AgentNotch.app"
VERSION="0.2.0"
BUNDLE_ID="io.armonia.agent-notch"
DISPLAY_NAME="agent-notch"
INSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)    OUTPUT="$2";  shift 2 ;;
        --version)   VERSION="$2"; shift 2 ;;
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --install)   INSTALL=1; shift ;;
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

# Resolve OUTPUT to an absolute path so the build-product copy works
# even when the user passes a relative argument from a sub-shell.
case "$OUTPUT" in
    /*) ABS_OUTPUT="$OUTPUT" ;;
    *)  ABS_OUTPUT="$REPO_ROOT/$OUTPUT" ;;
esac

# ─── Prereq checks ──────────────────────────────────────────────────────

if ! command -v swift >/dev/null 2>&1; then
    echo "❌ swift not found. Install Xcode from the App Store, then" >&2
    echo "   run:  xcode-select --install" >&2
    exit 1
fi

echo "[build-app] toolchain: $(swift --version | head -1)"

# ─── Swift build ────────────────────────────────────────────────────────

echo "[build-app] swift build -c release (this can take a few minutes the first time)…"
swift build -c release

# SwiftPM places the binary at .build/release/agent-notch. The bundle
# resources (Orb/) are emitted alongside as AgentNotch_AgentNotch.bundle.
BUILD_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE="$BUILD_DIR/agent-notch"
RESOURCE_BUNDLE="$BUILD_DIR/AgentNotch_AgentNotch.bundle"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "❌ executable not found at $EXECUTABLE" >&2
    exit 1
fi

# ─── Wipe and re-create the .app skeleton ───────────────────────────────

rm -rf "$ABS_OUTPUT"
mkdir -p "$ABS_OUTPUT/Contents/MacOS"
mkdir -p "$ABS_OUTPUT/Contents/Resources"

# ─── Copy executable ────────────────────────────────────────────────────

cp "$EXECUTABLE" "$ABS_OUTPUT/Contents/MacOS/agent-notch"
chmod +x "$ABS_OUTPUT/Contents/MacOS/agent-notch"

# ─── Copy resource bundle (Orb/ etc) ────────────────────────────────────

if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$ABS_OUTPUT/Contents/Resources/"
fi

# ─── Generate Info.plist ────────────────────────────────────────────────
# Built with PlistBuddy so we don't depend on a separate template file.

PLIST="$ABS_OUTPUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Clear dict" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en"               "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string agent-notch"             "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID"              "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0"          "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $DISPLAY_NAME"                 "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DISPLAY_NAME"          "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL"                   "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION"        "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION"                   "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0"                "$PLIST"
# LSUIElement = true → no Dock icon, no menu bar entry. Notch app is
# headless except for the panel.
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true"                             "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true"                 "$PLIST"
# TCC strings — without these, requestAuthorization / requestAccess
# either silently denies or crashes with "this app has crashed because
# it attempted to access privacy-sensitive data without a usage
# description".
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'agent-notch records short voice prompts during hover-to-talk. Audio is processed locally and only uploaded to the backend you configured.'" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSSpeechRecognitionUsageDescription string 'agent-notch uses on-device speech recognition to show live captions while you talk to your agents.'" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSAppleEventsUsageDescription string 'agent-notch opens your default browser to focus an orchestrator dashboard tab when you click a session in the sidebar.'" "$PLIST"

echo "[build-app] Info.plist written:"
echo "    bundle-id    = $BUNDLE_ID"
echo "    version      = $VERSION"
echo "    LSUIElement  = true (accessory app, no Dock icon)"
echo "    min macOS    = 14.0"

# ─── Ad-hoc codesign so Gatekeeper at least lets it run locally ─────────
# A Developer ID cert + notarytool flow is a separate `release.sh`.

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$ABS_OUTPUT" >/dev/null 2>&1 || true
    echo "[build-app] ad-hoc signed (sign -)"
else
    echo "[build-app] codesign not on PATH; skipping ad-hoc sign"
fi

echo "[build-app] bundle ready at: $ABS_OUTPUT"

# ─── Optional install into /Applications ────────────────────────────────

if [[ "$INSTALL" -eq 1 ]]; then
    # Derive the install path from the OUTPUT basename so a custom
    # --bundle-id / --output combination doesn't silently overwrite
    # the default /Applications/AgentNotch.app belonging to a
    # different build. e.g.
    #   --output dist/AgentNotchDev.app  →  /Applications/AgentNotchDev.app
    DEST_NAME="$(basename "$ABS_OUTPUT")"
    DEST="/Applications/$DEST_NAME"
    echo "[build-app] installing to $DEST (you may be prompted for sudo)…"
    sudo rm -rf "$DEST"
    sudo cp -R "$ABS_OUTPUT" "$DEST"
    echo "[build-app] installed. Launch with:  open '$DEST'"
fi

echo ""
echo "Launch with:"
echo "    open '$ABS_OUTPUT'"
echo ""
echo "If TCC prompts (Microphone / Speech / Accessibility) don't appear,"
echo "they're already granted. Open System Settings → Privacy & Security"
echo "to verify."
