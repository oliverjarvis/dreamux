#!/usr/bin/env bash
# Build Clayspace via SwiftPM and assemble a runnable .app bundle.
#
# Usage: ./Scripts/make-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Clayspace.app"
PLIST="$ROOT/Sources/Clayspace/Resources/Info.plist"

cd "$ROOT"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Clayspace"

if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clayspace"
cp "$PLIST" "$APP/Contents/Info.plist"

# Bundle SwiftPM resource bundles next to the executable so they're found.
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$bundle" ]] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# Bundle the agent-hook CLI so we can prepend its directory to the spawned
# shell's PATH. Coding agents (Claude Code, aider, …) can invoke
# `clayspace-hook stop` from their hook config to get the same OSC-9 push
# notification flow that's powering the in-app badges.
mkdir -p "$APP/Contents/Resources/bin"
cp "$ROOT/Tools/clayspace-hook" "$APP/Contents/Resources/bin/clayspace-hook"
chmod +x "$APP/Contents/Resources/bin/clayspace-hook"

# Ad-hoc sign so launchd is willing to run it.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
