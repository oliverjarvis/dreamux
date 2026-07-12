#!/usr/bin/env bash
# Build a tagged Dreamux bundle and launch it side-by-side with your main
# instance. There is deliberately NO single-instance guard: the tagged
# build has its own bundle id, so its signals.db, emit socket,
# projects.json, and AppKit window-restoration state never collide with
# the untagged app.
#
# Usage: ./Scripts/dev-dogfood.sh [debug|release] [tag]   (tag defaults: dogfood)
set -euo pipefail

CONFIG="${1:-debug}"
TAG="${2:-dogfood}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/Scripts/make-app.sh" "$CONFIG" "$TAG"

APP="$ROOT/Dreamux-$TAG.app"
# `open -n` forces a new instance; -ApplePersistenceIgnoreState YES keeps
# a manual/dev launch from restoring stale windows (matches the e2e
# harness convention).
open -n "$APP" --args -ApplePersistenceIgnoreState YES

echo "Launched $APP side-by-side (tag: $TAG)."
