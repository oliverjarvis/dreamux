#!/usr/bin/env bash
#
# Install the `dreamux` CLI by linking your installed Dreamux app's binary
# onto your PATH (the same binary handles both the GUI and the CLI — see the
# README's "CLI" section). Safe to re-run; safe to pipe from curl.
#
#   curl -fsSL https://raw.githubusercontent.com/oliverjarvis/dreamux/main/install.sh | bash
#
# Requires Dreamux.app to be installed/built first.

set -euo pipefail

BIN_NAME="dreamux"

# Locate the Dreamux binary — an installed app or a build in the CWD.
SRC=""
for candidate in \
  "/Applications/Dreamux.app/Contents/MacOS/Dreamux" \
  "$HOME/Applications/Dreamux.app/Contents/MacOS/Dreamux" \
  "$PWD/Dreamux.app/Contents/MacOS/Dreamux"
do
  if [ -x "$candidate" ]; then SRC="$candidate"; break; fi
done

if [ -z "$SRC" ]; then
  echo "dreamux install: couldn't find Dreamux.app." >&2
  echo "  Install it to /Applications (or build it with ./Scripts/make-app.sh), then re-run." >&2
  exit 1
fi

# Pick the first writable bin dir; create ~/.local/bin if needed.
DEST_DIR=""
for dir in "/usr/local/bin" "$HOME/.local/bin"; do
  mkdir -p "$dir" 2>/dev/null || true
  if [ -d "$dir" ] && [ -w "$dir" ]; then DEST_DIR="$dir"; break; fi
done

if [ -z "$DEST_DIR" ]; then
  echo "dreamux install: no writable install dir (/usr/local/bin, ~/.local/bin)." >&2
  echo "  Re-run with sudo, or symlink manually:" >&2
  echo "    ln -sf \"$SRC\" /usr/local/bin/$BIN_NAME" >&2
  exit 1
fi

ln -sf "$SRC" "$DEST_DIR/$BIN_NAME"
echo "Installed $BIN_NAME -> $SRC"
echo "         at $DEST_DIR/$BIN_NAME"

case ":$PATH:" in
  *":$DEST_DIR:"*) echo "Run: $BIN_NAME help" ;;
  *) echo "Note: add $DEST_DIR to your PATH, then run: $BIN_NAME help" ;;
esac
