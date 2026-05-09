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

# Ad-hoc sign so launchd is willing to run it.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
