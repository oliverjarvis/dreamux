# Self-Install & Self-Update — Design

**Date:** 2026-07-30
**Status:** Approved for implementation

## Goal

Make Dreamux developable *inside itself*: one command installs the app into an
Applications folder, and the **same command** updates it later — including when
it's invoked from a terminal running inside the very Dreamux instance being
updated. This is roadmap step 1 ("local rebuild/reopen") done properly; Homebrew
cask / Developer ID / Sparkle remain later steps.

## Approaches considered

- **A. Idempotent `Scripts/install-app.sh` (chosen).** Install == update ==
  re-run the script. Handles the running-app swap and the inside-Dreamux
  relaunch handoff. Smallest surface that makes self-hosting real.
- **B. In-app "Update Dreamux" menu item.** Better dogfooding UX, but needs UI,
  progress, and failure surfaces; explicitly deferred on the distribution
  roadmap. The `DreamuxSourceCheckout` stamp added here makes it cheap later.
- **C. Homebrew cask / GitHub releases.** Real distribution, blocked on the
  Apple Developer Program cert + notarization; wrong tool for the inner dev
  loop anyway.

## Design

### 1. Build-identity stamps (`Scripts/make-app.sh`)

Every built bundle's **copied** plist (source plist never touched — same rule
as tag stamping) gains:

- `CFBundleVersion` = `git rev-list --count HEAD` — monotonic build number, so
  an installed app and a candidate build are comparable.
- `DreamuxBuildCommit` = short SHA, with `-dirty` appended when tracked files
  are modified.
- `DreamuxBuildDate` = UTC ISO-8601 build time.
- `DreamuxSourceCheckout` = absolute repo root that produced the build (feeds a
  future in-app updater; also answers "which worktree built this?").

Stamps are skipped (except date + checkout) outside a git work tree. This
amends the "untagged bundles are byte-identical" note from the self-hosting
isolation spec: bundles now differ per commit in *metadata only* — no path,
bundle-id, or behavioral key derives from these fields, so the isolation
design's invariants hold.

### 2. `Scripts/install-app.sh` — install and update, one idempotent command

```
./Scripts/install-app.sh [release|debug] [--dest DIR] [--no-relaunch]
```

- **Config defaults to `release`** (installs are for daily driving; `debug` is
  for installing a build you're actively poking at).
- **Destination resolution:** `--dest` wins; else an existing install wins
  (`/Applications/Dreamux.app`, then `~/Applications/Dreamux.app`) so updates
  land where the app actually lives; else `/Applications` when writable
  (admin users — no sudo needed), else `~/Applications`. If installs exist in
  *both* standard locations, warn loudly — two same-id copies confuse
  LaunchServices and Spotlight.
- **Build + stage:** run `make-app.sh`, then `ditto` the bundle to a hidden
  staging path in the destination folder (same volume) so the final swap is
  two instant `mv`s, not a seconds-long copy window.
- **Not-running path:** swap inline (old → aside, staging → dest, delete
  aside), then `open` the app (skipped with `--no-relaunch`).
- **Running path (the self-update case):** hand the tail off to a detached
  phase-2 (`nohup` + a new session via perl `POSIX::setsid` — macOS ships no
  setsid binary) logging to `$TMPDIR/dreamux-install-app.log`, because a
  script started from a terminal inside Dreamux dies with the app's process
  group when the app quits. Phase 2: gracefully quit via AppleScript
  (`tell application id "com.dreamux.Dreamux" to quit` — SIGTERM would skip
  AppKit's termination path, including the quit-confirmation shown when live
  runs exist), wait up to 30s with the clock started *before* the quit event
  and the AppleScript wrapped in `with timeout of 5 seconds` (osascript's
  default AppleEvent timeout is ~2 minutes), **abort without swapping** on
  timeout (never force-kill an app that may host live Claude runs), swap,
  `open`, then verify the new pid differs from the old (quit+open has been
  observed reactivating the same pid).
- **Refused combination:** running app + `--no-relaunch` errors out — swapping
  a live app's bundle out from under it breaks lazy resource loading; the
  honest options are "let me relaunch it" or "quit it yourself first".
- The running-instance check matches the **destination binary path** as a
  fixed string (`ps` + `grep -F`), so tagged side-by-side builds
  (`Dreamux-dogfood.app`) are never touched.

### 3. Launch must not block on `~/Documents` (found by the live update test)

The first live self-update run exposed a launch defect that breaks the whole
loop: `DreamuxApp.init()` → `ProjectStore.init()` → `refresh()` enumerated
`~/Documents/Dreamux` synchronously on the main thread, and iCloud's bird
daemon blocked that `open()` in the kernel for ~5 minutes — an app that never
finished launching, couldn't draw a window, and couldn't service the
updater's quit AppleEvent (osascript error `-1712`). Fix, in `ProjectStore`:

- Split `refresh()` into `scanProjectFolders(root:)` (the blocking I/O,
  `nonisolated static`) and `reconciled(current:scanned:)` (the pure merge) —
  both unit-testable without a store instance.
- `refresh()` now runs the scan detached and applies the result on the main
  actor; a `scanGeneration` counter (bumped by every scan start and by
  `createProject`/`deleteProject`) discards scans that raced a mutation.
- `refreshAndWait()` is the awaitable variant; `LaunchGate.resolve()` awaits
  it (via `.task`) before routing, which keeps e2e auto-open deterministic.
- `load()` no longer stats each cached project's folder (same launch-time
  hazard); vanished folders drop out when the first scan reconciles.

### 4. README

Install section becomes the one command; "Updating" becomes `git pull` +
re-run, with a note that it's safe from a terminal inside Dreamux.

## Testing

Shell-only change; verified end-to-end on the real machine (per the "real data
beats fixtures" review lesson):

1. Fresh-install run → bundle lands at destination, plist shows stamped
   commit/build number, app launches.
2. Second run **while the app is running** → detached handoff quits, swaps,
   relaunches; pid changed; log shows each step; installed plist shows the new
   stamp.
3. Stale-other-location warning fires when both install locations exist.

## Follow-ups (out of scope)

- In-app "Update Dreamux…" menu item driven by `DreamuxSourceCheckout`.
- `dreamux update` CLI subcommand (needs a story for locating the checkout).
- Developer ID signing + notarization → GitHub Releases → Homebrew cask
  (distribution roadmap steps 2–3).
