#!/usr/bin/env bash
# End-to-end harness entry point for Clayspace.
#
# Builds the app bundle, prepares a throwaway sandbox (projects root,
# state dir, seeded git repos from the fixture sample apps), then hands
# off to driver.py which launches the app and runs the scenarios over
# the automation socket (see PROTOCOL.md). Screenshots and logs land in
# $ARTIFACTS; the exit status is non-zero if any scenario fails.
#
# Usage: ./Scripts/e2e/run-e2e.sh
#   ARTIFACTS=/some/dir  override the artifacts output directory
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

"$ROOT/Scripts/make-app.sh" debug

# Per-run sandbox: everything the app touches (projects root, state
# dir, seed repos) lives under here. driver.py removes it on success
# and keeps it for debugging on failure.
SANDBOX="$(mktemp -d)"

# Artifacts (screenshots, app logs, failure state dumps): wiped fresh
# every run so "latest" only ever shows the most recent pass/fail.
ARTIFACTS="${ARTIFACTS:-$ROOT/artifacts/e2e/latest}"
rm -rf "$ARTIFACTS"
mkdir -p "$ARTIFACTS"

# The unix socket path must stay short (Darwin caps sun_path at ~103
# bytes), so it lives in /tmp rather than inside the mktemp sandbox.
SOCKET="/tmp/clayspace-e2e-$$.sock"

PROJECT_NAME="demo-project"
mkdir -p "$SANDBOX/projects/$PROJECT_NAME" "$SANDBOX/state" "$SANDBOX/seed"

# Seed repos: git-init + commit copies of the fixture sample apps. The
# app imports these via `addLocalRepo` (a local `git clone --bare`),
# so they just need real history — committed with an explicit identity
# so this works on machines without global git config.
seed_repo() {
    local name="$1"
    local src="$ROOT/Tests/Fixtures/sample-apps/$name"
    local dst="$SANDBOX/seed/$name"
    mkdir -p "$dst"
    cp "$src/server.py" "$src/clayspace-runner.snippet.toml" "$dst/"
    git -C "$dst" init --quiet --initial-branch=main
    git -C "$dst" add -A
    git -C "$dst" \
        -c user.name='Clayspace E2E' \
        -c user.email='e2e@clayspace.local' \
        commit --quiet -m "seed $name fixture"
}
seed_repo portenv-server
seed_repo fixedport-server

export ARTIFACTS
export E2E_APP_BINARY="$ROOT/Clayspace.app/Contents/MacOS/Clayspace"
export E2E_SANDBOX="$SANDBOX"
export E2E_SOCKET="$SOCKET"
export E2E_SEED_DIR="$SANDBOX/seed"
export E2E_PROJECT_NAME="$PROJECT_NAME"
export CLAYSPACE_CLAUDE_BIN="$ROOT/Tests/Fixtures/bin/claude"
export CLAYSPACE_GH_BIN="$ROOT/Tests/Fixtures/bin/gh"

exec python3 "$ROOT/Scripts/e2e/driver.py"
