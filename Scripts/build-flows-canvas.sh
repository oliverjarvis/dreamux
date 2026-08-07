#!/usr/bin/env bash
# Rebuild the Flows canvas web bundle into Sources/Dreamux/Resources/FlowsCanvas.
#
# The OUTPUT is committed, so `swift build` alone gets you a working app —
# node is needed only to CHANGE the canvas. `bundle.hash` records a digest
# of the source that produced this bundle; FlowsCanvasBundleTests recomputes
# it and fails `swift test` if you edited the TSX and forgot to rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/web/flows-canvas"
OUT="$ROOT/Sources/Dreamux/Resources/FlowsCanvas"

command -v npm >/dev/null || { echo "npm not found — node is required to rebuild the canvas" >&2; exit 1; }

cd "$WEB"
if [[ -f package-lock.json ]]; then npm ci; else npm install; fi
npm run typecheck
# TODO(Task 6): drop --passWithNoTests once test/layout.test.ts exists.
# The first vitest suites arrive in Tasks 6-7; until then `vitest run` exits
# 1 on an empty suite and would abort this script under `set -e`.
npm test -- --passWithNoTests
npm run build

mkdir -p "$OUT"
cp "$WEB/index.html" "$OUT/index.html"

# --- bundle.hash -------------------------------------------------------
# Stream: for each file, "<relpath>\n" + raw bytes + "\n", files sorted
# byte-wise (LC_ALL=C) by relpath. Keep in lockstep with
# Tests/DreamuxTests/FlowsCanvasBundleTests.swift.
hash_stream() {
    local file
    while IFS= read -r file; do
        printf '%s\n' "$file"
        cat "$WEB/$file"
        printf '\n'
    done < <(
        {
            cd "$WEB" && find src -type f | sed 's|^\./||'
            echo "package.json"
        } | LC_ALL=C sort
    )
}

HASH="$(hash_stream | shasum -a 256 | awk '{print $1}')"
printf '%s' "$HASH" > "$OUT/bundle.hash"

echo "Flows canvas built → $OUT (hash $HASH)"
