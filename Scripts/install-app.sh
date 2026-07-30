#!/usr/bin/env bash
# Install or update Dreamux.app from this checkout — one idempotent command
# for both. Builds via make-app.sh, stages a copy next to the destination,
# and swaps it in with two instant `mv`s.
#
#   ./Scripts/install-app.sh [release|debug] [--dest DIR] [--no-relaunch]
#
# Destination: --dest DIR (the app lands at DIR/Dreamux.app); otherwise an
# existing install wins (/Applications, then ~/Applications), otherwise
# /Applications when writable (admin — no sudo needed), else ~/Applications.
#
# Safe to run from a terminal INSIDE Dreamux: when the installed app is
# running, the quit → swap → relaunch tail runs detached in its own session
# (logging to $TMPDIR/dreamux-install-app.log), so it survives the app
# tearing down its process group on quit. The app is only ever quit
# gracefully (AppleScript quit — SIGTERM would skip AppKit's termination
# path, including its quit-confirmation when live runs exist); if it won't
# quit within 30s the update aborts with the old install untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/Scripts/install-app.sh"
BUNDLE_ID="com.dreamux.Dreamux"
LOG="${TMPDIR:-/tmp}/dreamux-install-app.log"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# All pids whose command line contains the destination binary path (fixed-
# string match, so tagged side-by-side bundles are never touched).
pids_at() {
    ps ax -o pid= -o command= | grep -F "$1/Contents/MacOS/Dreamux" \
        | grep -v grep | awk '{print $1}' || true
}

# Swap STAGING into DEST: old moved aside, staging moved in, aside removed.
# Both mv's are same-volume renames, so the window with no app is ~instant.
swap_in() {
    local staging="$1" dest="$2"
    if [[ -d "$dest" ]]; then
        local aside="${dest%.app}.old.$$.app"
        mv "$dest" "$aside"
        mv "$staging" "$dest"
        rm -rf "$aside"
    else
        mv "$staging" "$dest"
    fi
}

# ---- Phase 2: detached quit → swap → relaunch → verify -------------------
# install-app.sh --phase2 DEST STAGING "OLD_PIDS"
if [[ "${1:-}" == "--phase2" ]]; then
    DEST="$2"; STAGING="$3"; OLD_PIDS="$4"
    echo "[$(ts)] phase2: updating $DEST (old pids: $OLD_PIDS)"

    # Clock starts BEFORE the quit event: osascript itself can block on a
    # busy app, and that wait counts against the budget. The AppleScript
    # `with timeout` makes osascript return promptly instead of sitting
    # out its 2-minute default AppleEvent timeout — the quit event stays
    # queued in the app either way. 30s covers the app's own quit
    # confirmation (shown when live runs would be killed).
    deadline=$(( $(date +%s) + 30 ))
    for pid in $OLD_PIDS; do
        kill -0 "$pid" 2>/dev/null || continue
        echo "[$(ts)] phase2: asking Dreamux (pid $pid) to quit"
        osascript \
            -e "with timeout of 5 seconds" \
            -e "if application id \"$BUNDLE_ID\" is running then tell application id \"$BUNDLE_ID\" to quit" \
            -e "end timeout" || true
        break   # one quit event covers the app; now wait on every pid
    done

    for pid in $OLD_PIDS; do
        while kill -0 "$pid" 2>/dev/null; do
            if (( $(date +%s) >= deadline )); then
                echo "[$(ts)] phase2: Dreamux (pid $pid) didn't quit within 30s — aborting, old install untouched." >&2
                echo "[$(ts)] phase2: likely causes: its quit-confirmation dialog is waiting for a click (live runs), or the main thread is blocked (sample $pid to see where). Quit it, then re-run the installer." >&2
                rm -rf "$STAGING"
                exit 1
            fi
            sleep 0.5
        done
    done

    swap_in "$STAGING" "$DEST"
    echo "[$(ts)] phase2: swapped in new bundle ($(plutil -extract DreamuxBuildCommit raw "$DEST/Contents/Info.plist" 2>/dev/null || echo '?'))"

    open "$DEST"
    NEW_PID=""
    for _ in $(seq 1 20); do
        sleep 0.5
        for pid in $(pids_at "$DEST"); do
            case " $OLD_PIDS " in *" $pid "*) ;; *) NEW_PID="$pid" ;; esac
        done
        [[ -n "$NEW_PID" ]] && break
    done
    if [[ -n "$NEW_PID" ]]; then
        echo "[$(ts)] phase2: relaunched (pid $OLD_PIDS -> $NEW_PID). Done."
    else
        echo "[$(ts)] phase2: swap done but no new instance appeared within 10s — open it manually: open \"$DEST\"" >&2
        exit 1
    fi
    exit 0
fi

# ---- Phase 1: build, stage, and install or hand off ----------------------
CONFIG="release"
DEST_DIR=""
RELAUNCH=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        release|debug) CONFIG="$1"; shift ;;
        --dest)        DEST_DIR="${2:?--dest needs a directory}"; shift 2 ;;
        --no-relaunch) RELAUNCH=0; shift ;;
        *) echo "usage: ./Scripts/install-app.sh [release|debug] [--dest DIR] [--no-relaunch]" >&2; exit 2 ;;
    esac
done

SYS_DIR="/Applications"
USR_DIR="$HOME/Applications"
if [[ -z "$DEST_DIR" ]]; then
    if [[ -d "$SYS_DIR/Dreamux.app" && -d "$USR_DIR/Dreamux.app" ]]; then
        echo "warning: Dreamux.app exists in BOTH $SYS_DIR and $USR_DIR — updating $SYS_DIR; delete the other copy, two same-id installs confuse Spotlight/LaunchServices." >&2
        DEST_DIR="$SYS_DIR"
    elif [[ -d "$SYS_DIR/Dreamux.app" ]]; then DEST_DIR="$SYS_DIR"
    elif [[ -d "$USR_DIR/Dreamux.app" ]]; then DEST_DIR="$USR_DIR"
    elif [[ -w "$SYS_DIR" ]]; then DEST_DIR="$SYS_DIR"
    else DEST_DIR="$USR_DIR"
    fi
fi
mkdir -p "$DEST_DIR"
[[ -w "$DEST_DIR" ]] || { echo "error: $DEST_DIR is not writable" >&2; exit 1; }
DEST="$DEST_DIR/Dreamux.app"

"$ROOT/Scripts/make-app.sh" "$CONFIG"

STAGING="$DEST_DIR/.Dreamux.app.staging.$$"
trap 'rm -rf "$STAGING"' EXIT
ditto "$ROOT/Dreamux.app" "$STAGING"

NEW_COMMIT="$(plutil -extract DreamuxBuildCommit raw "$STAGING/Contents/Info.plist" 2>/dev/null || echo '?')"
NEW_BUILD="$(plutil -extract CFBundleVersion raw "$STAGING/Contents/Info.plist" 2>/dev/null || echo '?')"

OLD_PIDS="$(pids_at "$DEST" | tr '\n' ' ' | sed 's/ *$//')"

if [[ -n "$OLD_PIDS" ]]; then
    if [[ "$RELAUNCH" == 0 ]]; then
        echo "error: Dreamux is running (pid $OLD_PIDS) and an update requires a relaunch." >&2
        echo "       Re-run without --no-relaunch, or quit Dreamux first." >&2
        exit 1
    fi
    # The detached tail must outlive us AND the app's process-group kill on
    # quit — nohup alone shares our pgroup, so start a fresh session (macOS
    # ships no setsid binary; perl's POSIX::setsid stands in).
    trap - EXIT
    echo "[$(ts)] handing off to detached updater (build $NEW_BUILD, $NEW_COMMIT)" >>"$LOG"
    nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' -- \
        /bin/bash "$SELF" --phase2 "$DEST" "$STAGING" "$OLD_PIDS" \
        </dev/null >>"$LOG" 2>&1 &
    echo "Dreamux is running — quit/swap/relaunch handed off to a detached updater."
    echo "  build $NEW_BUILD ($NEW_COMMIT) -> $DEST"
    echo "  log: $LOG"
    echo "If Dreamux asks to confirm quitting (live runs), click Quit to let the update continue."
    echo "If this terminal lives inside Dreamux, it will close when the app quits; the update continues."
    exit 0
fi

swap_in "$STAGING" "$DEST"
echo "Installed build $NEW_BUILD ($NEW_COMMIT) -> $DEST"

# A CLI symlink pointing at a different install location keeps launching the
# stale copy — flag it (install.sh re-links it).
for link in /usr/local/bin/dreamux "$HOME/.local/bin/dreamux"; do
    target="$(readlink "$link" 2>/dev/null || true)"
    if [[ -n "$target" && "$target" != "$DEST/Contents/MacOS/Dreamux" ]]; then
        echo "note: $link -> $target (not this install) — re-run ./install.sh to fix." >&2
    fi
done

if [[ "$RELAUNCH" == 1 ]]; then
    open "$DEST"
    echo "Launched $DEST"
fi
