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

# Bundle our PATH-shim CLIs into Resources/bin so spawned shells can
# resolve them automatically. Two scripts ship today:
#
#   clayspace-hook  — emits OSC 9 notifications consumed by the PTY
#                     parser; agents call it from their hook config.
#   claude          — wraps the real Claude Code binary, injecting our
#                     hooks inline via --settings on every invocation
#                     so the user doesn't have to install anything to
#                     ~/.claude or .claude/settings.json.
mkdir -p "$APP/Contents/Resources/bin"
for tool in clayspace-hook claude; do
    cp "$ROOT/Tools/$tool" "$APP/Contents/Resources/bin/$tool"
    chmod +x "$APP/Contents/Resources/bin/$tool"
done

# Ad-hoc sign so launchd is willing to run it.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
