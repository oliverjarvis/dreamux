# Self-Hosting Isolation — Design

**Date:** 2026-07-12
**Status:** Settled (do not re-litigate)

## Goal

Let a *tagged / dev* Dreamux build run **side-by-side** with the user's main
Dreamux instance (and with other projects open) without the second process
seizing shared, bundle-id-keyed singletons — its own signals ledger, emit
socket, project list, and AppKit window-restoration state.

## Settled decisions

- **Embrace side-by-side.** No single-instance guard, no lock. Two Dreamux
  processes may run at once; isolation comes from giving a tagged build its own
  identity, not from blocking the second launch.
- **The bundle identifier is the keystone.** `signals.db` and the emit socket
  already derive from `Bundle.main.bundleIdentifier`, so stamping a unique
  `CFBundleIdentifier` into a tagged bundle automatically forks the db, socket,
  App Support dir, and window-restoration state. The remaining gaps are (a) the
  socket path takes no env input, (b) `projects.json` uses a literal `"Dreamux"`
  directory not keyed by bundle id.
- **Untagged builds must behave *exactly* as today** — every default path byte-
  identical. Isolation is opt-in via a build tag.
- **One shared helper owns bundle-id derivation.** Socket / db / projects.json
  must not each re-implement "derive per-bundle-id paths".

## The three fixes

### 1. De-singleton the emit socket (env input)

`SignalEmitSocketServer.defaultSocketPath()` (`SignalEmitSocketServer.swift:51`)
today derives the path solely from the bundle id
(`/tmp/dreamux-emit-com.dreamux.Dreamux.sock`). Make it honor a
`DREAMUX_EMIT_SOCKET` environment variable as **input** when set non-empty, else
fall back to today's exact bundle-id-derived path.

`DREAMUX_EMIT_SOCKET` is *already exported to child shells* by
`PTYShellSession.swift:173` (`env["DREAMUX_EMIT_SOCKET"] =
SignalEmitSocketServer.defaultSocketPath()`) and read by `Tools/dreamux-hook`
(`os.environ.get("DREAMUX_EMIT_SOCKET")`). This change makes the **parent**
process *read* the same variable it already exports.

**Consistency:** both `SignalBus.init` (bind, `SignalBus.swift:54`) and
`PTYShellSession` (export, line 173) call the *same* `defaultSocketPath()`. In
production the parent app has no `DREAMUX_EMIT_SOCKET` set → both derive
`/tmp/dreamux-emit-<bundleID>.sock`. If a wrapper launches the app *with*
`DREAMUX_EMIT_SOCKET` set, both bind and export honor the override — still
consistent. `SignalBus` still does `unlink(path)` then `bind` on that path.

### 2. Tagged bundle identity (make-app.sh)

`Scripts/make-app.sh` (`./Scripts/make-app.sh [debug|release]`) gains an
**optional tag** second argument: `./Scripts/make-app.sh debug dogfood`. When a
tag is given it stamps, into the **copied** `Contents/Info.plist` only (never the
source `Sources/Dreamux/Resources/Info.plist`):

- `CFBundleIdentifier` = `com.dreamux.Dreamux.<tag>`
- `CFBundleDisplayName` = `Dreamux (<tag>)`
- `CFBundleName` = `Dreamux (<tag>)`

and writes the bundle to a tag-distinct path (`Dreamux-<tag>.app`) so it neither
clobbers an untagged dev build in the same worktree nor collides in
LaunchServices. Untagged runs (`make-app.sh debug`) copy the plist verbatim to
`Dreamux.app` — **byte-identical to today**, including the existing
`rm -rf "$APP"` of that worktree's bundle.

Because the bundle id now differs, a tagged build automatically gets:
`~/Library/Application Support/com.dreamux.Dreamux.<tag>/signals.db`
(`SQLiteSignalStore.defaultURL`), `/tmp/dreamux-emit-com.dreamux.Dreamux.<tag>.sock`,
its own App Support dir, and its own AppKit window-restoration state.

### 3. projects.json isolation

`projects.json` lives at `ProjectStore.stateRootURL()` — today a literal
`~/Library/Application Support/Dreamux/` (`ProjectStore.swift:62-81`), *not* keyed
by bundle id, so two instances would last-writer-wins clobber it. The same
directory also backs `connections.json` (`ConnectionStore.swift:24`) and
`AppStudioData/<slug>` (`AppStudioView.swift:255`), so isolating it isolates
those for free.

Route it through the shared helper so a tagged build gets its own state dir,
while the untagged path stays byte-identical:

- `$DREAMUX_STATE_DIR` (existing e2e override) — highest priority, unchanged.
- else **untagged** → `<appSupport>/Dreamux` (legacy literal, byte-identical).
- else **tagged** → `<appSupport>/<bundleID>` — i.e. the *same* per-bundle-id
  dir that tag's `signals.db` sits in, co-locating a tag's whole state under one
  deletable folder.

## Components

### Shared helper: `BundleIdentity`

New file `Sources/Dreamux/BundleIdentity.swift`. A pure, dependency-injectable
enum that owns every per-bundle-id derivation. All functions take injectable
`bundleID:` / `env:` / `base:` params (with live defaults) so they unit-test
without touching `Bundle.main` or the real filesystem.

```swift
enum BundleIdentity {
    /// Untagged base id — also the fallback when Bundle.main has no id
    /// (XCTest host, CLI).
    static let baseBundleID = "com.dreamux.Dreamux"

    /// Effective CFBundleIdentifier, or baseBundleID when absent.
    static func bundleID(_ bundle: Bundle = .main) -> String

    /// Tag carried in `com.dreamux.Dreamux.<tag>` → `<tag>`; nil for the
    /// bare base id, an empty suffix, or any unrelated id.
    static func buildTag(bundleID id: String = bundleID()) -> String?

    /// Emit-socket path. `$DREAMUX_EMIT_SOCKET` (non-empty) wins; else
    /// `/tmp/dreamux-emit-<bundleID>.sock`.
    static func emitSocketPath(env: [String: String] = ProcessInfo.processInfo.environment,
                               bundleID id: String = bundleID()) -> String

    /// Per-bundle App Support dir `<base>/<bundleID>/` — home of signals.db.
    static func appSupportBundleDir(base: URL, bundleID id: String = bundleID()) -> URL

    /// State dir for projects.json / connections.json / AppStudioData.
    /// Untagged → `<base>/Dreamux` (legacy, byte-identical); tagged →
    /// `<base>/<bundleID>` (co-located with that tag's signals.db).
    static func stateDirectory(base: URL, bundleID id: String = bundleID()) -> URL
}
```

### Wiring (thin call-throughs; no behavior change when untagged)

- `SignalEmitSocketServer.defaultSocketPath()` → `BundleIdentity.emitSocketPath()`.
  `SignalBus` and `PTYShellSession` keep calling `defaultSocketPath()` unchanged.
- `SQLiteSignalStore.defaultURL()` → `BundleIdentity.appSupportBundleDir(base:)`
  (real `applicationSupportDirectory` as base) + `signals.db`.
- `ProjectStore.stateRootURL()` → `BundleIdentity.stateDirectory(base:)` for the
  non-override branch; `$DREAMUX_STATE_DIR` branch unchanged.
- `NotificationManager.swift:29` and `SQLiteSignalStore`/`SignalEmitSocketServer`
  drop their inline `?? "com.dreamux.Dreamux"` literals in favor of
  `BundleIdentity.bundleID()` / `.baseBundleID`.

### Relaunch: `Scripts/dev-dogfood.sh`

`./Scripts/dev-dogfood.sh [debug|release] [tag]` (tag defaults `dogfood`) builds
the tagged bundle via `make-app.sh` and launches it side-by-side:
`open -n "$ROOT/Dreamux-<tag>.app" --args -ApplePersistenceIgnoreState YES`. No
guard: distinct bundle id → no collision with the main instance.
`-ApplePersistenceIgnoreState YES` matches the manual-launch convention used by
the e2e harness.

## States & edge cases

| Scenario | Socket | signals.db | state dir (projects.json) |
| --- | --- | --- | --- |
| **Untagged default** (`Bundle.main` = base / nil, no env) | `/tmp/dreamux-emit-com.dreamux.Dreamux.sock` | `…/com.dreamux.Dreamux/signals.db` | `…/Dreamux/projects.json` |
| **Tagged** (`…Dreamux.dogfood`) | `/tmp/dreamux-emit-com.dreamux.Dreamux.dogfood.sock` | `…/com.dreamux.Dreamux.dogfood/signals.db` | `…/com.dreamux.Dreamux.dogfood/projects.json` |
| **`DREAMUX_EMIT_SOCKET` set** | override value (bind + export both) | (unaffected) | (unaffected) |
| **`DREAMUX_STATE_DIR` set** (e2e) | (unaffected) | (unaffected) | `<override>/projects.json` |
| **Two instances** (main + dogfood) | two distinct sockets | two distinct dbs | two distinct project lists — no clobber |
| Empty-suffix id `com.dreamux.Dreamux.` | — | — | treated as untagged (buildTag → nil) |

## Testing approach

- **Pure `BundleIdentity` unit tests** (no `Bundle.main`, no real FS) are the
  authoritative pins for the untagged defaults: explicit `bundleID:` args assert
  exact literal strings (`/tmp/dreamux-emit-com.dreamux.Dreamux.sock`,
  `<base>/Dreamux`, `<base>/com.dreamux.Dreamux`), plus tagged derivations and
  the `DREAMUX_EMIT_SOCKET` override (set / empty / unset).
- **Wiring tests** assert the real entry points route through the helper without
  asserting machine paths: `defaultSocketPath() == BundleIdentity.emitSocketPath()`;
  `defaultURL()` ends in `signals.db` under a parent dir equal to
  `BundleIdentity.bundleID()`; `stateRootURL().lastPathComponent == "Dreamux"`
  when untagged (skipped if `DREAMUX_STATE_DIR` is set).
- **make-app.sh / Info.plist / dev-dogfood.sh** are shell/plist — verified by
  documented manual commands (`plutil -p …/Info.plist | grep CFBundleIdentifier`;
  source-plist-unchanged grep; two-process / two-socket checks). Not built here.

## File list

- **Create** `Sources/Dreamux/BundleIdentity.swift`
- **Modify** `Sources/Dreamux/Signals/SignalEmitSocketServer.swift` (`defaultSocketPath`)
- **Modify** `Sources/Dreamux/Signals/SQLiteSignalStore.swift` (`defaultURL`)
- **Modify** `Sources/Dreamux/Models/ProjectStore.swift` (`stateRootURL`)
- **Modify** `Sources/Dreamux/Shell/NotificationManager.swift` (bundle-id literal)
- **Modify** `Scripts/make-app.sh` (optional tag arg)
- **Create** `Scripts/dev-dogfood.sh`
- **Create** tests: `Tests/DreamuxTests/BundleIdentityTests.swift`; extend
  `SignalEmitSocketTests` / a store test / a project-store test with wiring pins.

## Follow-ups (out of scope — do NOT plan tasks)

- **MCPInstaller hardcoded dev paths** (`MCPInstaller.swift:104-107`). Also the
  MCP bridge (`mcp/dreamux-signals-mcp.ts:43,59`) picks the *most-recently-
  modified* `com.dreamux.*/signals.db` when scanning — with two bundles present
  it may bind an MCP to the wrong instance. Revisit once tagged builds are common.
- **FileTreeStore not pruning `.build`.**
- **Global Claude session registry** (shared across instances; not bundle-keyed).
