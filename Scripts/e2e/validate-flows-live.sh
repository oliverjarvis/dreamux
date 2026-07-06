#!/usr/bin/env bash
# Semi-live validation for the flows tailer/adapter: parses a READ-ONLY
# copy of this machine's real ~/.claude state to confirm the transcript
# and subagent-meta parsers hold up against real shape, without ever
# touching the user's running app or their live ~/.claude.
#
# Only `sessions` and `projects` are copied (registry entries and
# transcripts/metas) — never `ide`, `daemon*`, or `jobs`. The excludes
# below are kept even though those directories aren't rsync'd as
# top-level sources, as defense in depth against either source tree
# ever growing a like-named subdirectory.
#
# Usage: ./Scripts/e2e/validate-flows-live.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

CLAUDE_HOME_COPY="$SANDBOX/claude-home"
mkdir -p "$CLAUDE_HOME_COPY"

rsync -a \
    --exclude 'ide' --exclude 'daemon*' --exclude 'jobs' \
    "$HOME/.claude/sessions" "$HOME/.claude/projects" \
    "$CLAUDE_HOME_COPY/"

cd "$ROOT"
DREAMUX_LIVE_VALIDATION=1 DREAMUX_CLAUDE_HOME="$CLAUDE_HOME_COPY" \
    swift test --filter LiveShapeValidationTests
