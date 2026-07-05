#!/usr/bin/env bash
# Build Dreamux via SwiftPM and assemble a runnable .app bundle.
#
# Usage: ./Scripts/make-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Dreamux.app"
PLIST="$ROOT/Sources/Dreamux/Resources/Info.plist"
ICON="$ROOT/Sources/Dreamux/Resources/AppIcon.icns"

cd "$ROOT"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Dreamux"

if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Dreamux"
cp "$PLIST" "$APP/Contents/Info.plist"

# App icon: CFBundleIconFile in Info.plist points at "AppIcon", so the
# compiled .icns must land at Contents/Resources/AppIcon.icns.
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# Bundle SwiftPM resource bundles next to the executable so they're found.
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$bundle" ]] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# Bundle our PATH-shim CLIs into Resources/bin so spawned shells can
# resolve them automatically. Two scripts ship today:
#
#   dreamux-hook  — emits OSC 9 notifications consumed by the PTY
#                     parser; agents call it from their hook config.
#   claude          — wraps the real Claude Code binary, injecting our
#                     hooks inline via --settings on every invocation
#                     so the user doesn't have to install anything to
#                     ~/.claude or .claude/settings.json.
mkdir -p "$APP/Contents/Resources/bin"
for tool in dreamux-hook claude; do
    cp "$ROOT/Tools/$tool" "$APP/Contents/Resources/bin/$tool"
    chmod +x "$APP/Contents/Resources/bin/$tool"
done

# Bundle our ZDOTDIR shim. PTYShellSession sets ZDOTDIR to this folder
# when spawning zsh so the user's normal rc files load *first* (via
# `source $HOME/...`) and we re-prepend Dreamux/bin afterward — the
# only reliable way to keep our shims ahead of Homebrew/nvm/asdf.
mkdir -p "$APP/Contents/Resources/zdotdir"
for f in .zshenv .zprofile .zshrc .zlogin; do
    if [[ -e "$ROOT/Tools/zdotdir/$f" ]]; then
        cp "$ROOT/Tools/zdotdir/$f" "$APP/Contents/Resources/zdotdir/$f"
    fi
done

# Bundle the dreamux-signals MCP server (script + pinned deps) so
# MCPInstaller's Resources/mcp lookup resolves no matter where the app
# was built from — worktree builds and moved checkouts included. The
# dev-path fallback in resolveScriptPath() still covers a bundle
# without deps (e.g. bun missing on the build machine).
if [[ -f "$ROOT/mcp/dreamux-signals-mcp.ts" ]]; then
    mkdir -p "$APP/Contents/Resources/mcp"
    cp "$ROOT/mcp/dreamux-signals-mcp.ts" \
       "$ROOT/mcp/package.json" \
       "$ROOT/mcp/bun.lock" \
       "$APP/Contents/Resources/mcp/"
    # Same probe order as MCPInstaller.resolveBunPath: official installer,
    # Homebrew, then newest asdf install. PATH's shim is unreliable here.
    BUN=""
    for candidate in "$HOME/.bun/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
        [[ -x "$candidate" ]] && BUN="$candidate" && break
    done
    if [[ -z "$BUN" && -d "$HOME/.asdf/installs/bun" ]]; then
        latest="$(ls "$HOME/.asdf/installs/bun" | sort -r | head -1)"
        [[ -x "$HOME/.asdf/installs/bun/$latest/bin/bun" ]] && BUN="$HOME/.asdf/installs/bun/$latest/bin/bun"
    fi
    if [[ -n "$BUN" ]]; then
        (cd "$APP/Contents/Resources/mcp" && "$BUN" install --frozen-lockfile --silent) \
            || echo "warning: bun install for bundled MCP failed; dev-path fallback still applies" >&2
    else
        echo "warning: bun not found; bundled MCP ships without node_modules" >&2
    fi
fi

# Ad-hoc sign so launchd is willing to run it.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
