# Self-Hosting Isolation Implementation Plan

**Goal:** Let a tagged/dev Dreamux build run side-by-side with the user's main
instance without seizing shared, bundle-id-keyed singletons — its own signals
db, emit socket, and project list — while untagged builds stay byte-identical.

**Architecture:** A single `BundleIdentity` helper owns every per-bundle-id path
derivation (socket, App Support dir, state dir) and the `DREAMUX_EMIT_SOCKET`
env input. The socket server, signals store, and project store become thin
call-throughs to it. A tag argument to `make-app.sh` stamps a unique
`CFBundleIdentifier` into the copied `Info.plist`, which — because the db/socket/
state paths key off the bundle id — automatically forks all shared state; a
`dev-dogfood.sh` launches the tagged bundle side-by-side.

**Tech Stack:** Swift / SwiftPM, XCTest under `Tests/DreamuxTests/`, Foundation,
`bash` + `plutil` for bundle assembly. No new third-party dependencies.

## Global Constraints

- Swift/SwiftPM. Tests are XCTest under `Tests/DreamuxTests/`. Build: `swift build`. Test: `swift test --filter <Name>`.
- BEHAVIOR PRESERVATION: with no `DREAMUX_EMIT_SOCKET` set and no build tag, the emit socket path, `signals.db` path, and `projects.json` path must be EXACTLY what they are today. Add tests that pin the untagged/default paths.
- No new third-party dependencies.
- A single shared helper should own "derive per-bundle-id paths" so socket/db/projects.json don't each re-implement it.

---

### Task 1: `BundleIdentity` shared helper + default-path pins

**Files:** Create `Sources/Dreamux/BundleIdentity.swift`; Create `Tests/DreamuxTests/BundleIdentityTests.swift`.
**Interfaces:** Consumes — none. Produces — `BundleIdentity.baseBundleID: String`; `BundleIdentity.bundleID(_ bundle: Bundle = .main) -> String`; `BundleIdentity.buildTag(bundleID:) -> String?`; `BundleIdentity.emitSocketPath(env:bundleID:) -> String`; `BundleIdentity.appSupportBundleDir(base:bundleID:) -> URL`; `BundleIdentity.stateDirectory(base:bundleID:) -> URL`.

- [ ] Step: Write the failing test — `Tests/DreamuxTests/BundleIdentityTests.swift`:

```swift
import XCTest
@testable import Dreamux

/// Pins the untagged default derivations byte-for-byte and covers the
/// tagged / env-override branches — all pure, no Bundle.main, no real FS.
final class BundleIdentityTests: XCTestCase {
    private let base = "com.dreamux.Dreamux"
    private let tagged = "com.dreamux.Dreamux.dogfood"

    func testBuildTagUntaggedIsNil() {
        XCTAssertNil(BundleIdentity.buildTag(bundleID: base))
    }

    func testBuildTagEmptySuffixIsNil() {
        XCTAssertNil(BundleIdentity.buildTag(bundleID: base + "."))
    }

    func testBuildTagUnrelatedIsNil() {
        XCTAssertNil(BundleIdentity.buildTag(bundleID: "com.example.Other"))
    }

    func testBuildTagTagged() {
        XCTAssertEqual(BundleIdentity.buildTag(bundleID: tagged), "dogfood")
    }

    func testEmitSocketDefaultUntaggedIsExactToday() {
        XCTAssertEqual(
            BundleIdentity.emitSocketPath(env: [:], bundleID: base),
            "/tmp/dreamux-emit-com.dreamux.Dreamux.sock"
        )
    }

    func testEmitSocketDefaultTagged() {
        XCTAssertEqual(
            BundleIdentity.emitSocketPath(env: [:], bundleID: tagged),
            "/tmp/dreamux-emit-com.dreamux.Dreamux.dogfood.sock"
        )
    }

    func testEmitSocketEnvOverrideWins() {
        XCTAssertEqual(
            BundleIdentity.emitSocketPath(env: ["DREAMUX_EMIT_SOCKET": "/tmp/custom.sock"], bundleID: base),
            "/tmp/custom.sock"
        )
    }

    func testEmitSocketEmptyEnvFallsBackToDerived() {
        XCTAssertEqual(
            BundleIdentity.emitSocketPath(env: ["DREAMUX_EMIT_SOCKET": ""], bundleID: base),
            "/tmp/dreamux-emit-com.dreamux.Dreamux.sock"
        )
    }

    func testAppSupportBundleDirUntaggedIsExactToday() {
        let dir = BundleIdentity.appSupportBundleDir(base: URL(fileURLWithPath: "/base"), bundleID: base)
        XCTAssertEqual(dir.path, "/base/com.dreamux.Dreamux")
    }

    func testAppSupportBundleDirTagged() {
        let dir = BundleIdentity.appSupportBundleDir(base: URL(fileURLWithPath: "/base"), bundleID: tagged)
        XCTAssertEqual(dir.path, "/base/com.dreamux.Dreamux.dogfood")
    }

    func testStateDirectoryUntaggedIsLegacyDreamux() {
        let dir = BundleIdentity.stateDirectory(base: URL(fileURLWithPath: "/base"), bundleID: base)
        XCTAssertEqual(dir.path, "/base/Dreamux")
    }

    func testStateDirectoryTaggedUsesBundleIDDir() {
        let dir = BundleIdentity.stateDirectory(base: URL(fileURLWithPath: "/base"), bundleID: tagged)
        XCTAssertEqual(dir.path, "/base/com.dreamux.Dreamux.dogfood")
    }
}
```

- [ ] Step: Run it — expect FAIL: `swift test --filter BundleIdentityTests` → fails to compile (`cannot find 'BundleIdentity' in scope`).

- [ ] Step: Implement — `Sources/Dreamux/BundleIdentity.swift`:

```swift
import Foundation

/// Single owner of every per-bundle-id derivation: the emit-socket path
/// (and its `DREAMUX_EMIT_SOCKET` env input), the App Support dir that
/// holds `signals.db`, and the state dir that holds `projects.json` /
/// `connections.json` / `AppStudioData`.
///
/// The keystone of self-hosting isolation: a tagged debug build stamps a
/// unique `CFBundleIdentifier` (`com.dreamux.Dreamux.<tag>`), so every
/// path below forks automatically while untagged builds stay byte-
/// identical. All functions take injectable `bundleID` / `env` / `base`
/// params so they unit-test without touching `Bundle.main` or the real FS.
enum BundleIdentity {
    /// The untagged base identifier — also the fallback when `Bundle.main`
    /// has no id (the XCTest host, the `dreamux` CLI).
    static let baseBundleID = "com.dreamux.Dreamux"

    /// Effective `CFBundleIdentifier`, or `baseBundleID` when absent.
    static func bundleID(_ bundle: Bundle = .main) -> String {
        bundle.bundleIdentifier ?? baseBundleID
    }

    /// The build tag carried in a tagged id (`com.dreamux.Dreamux.<tag>`
    /// → `<tag>`); nil for the bare base id, an empty suffix, or any id
    /// that isn't a suffix of the base.
    static func buildTag(bundleID id: String = bundleID()) -> String? {
        let prefix = baseBundleID + "."
        guard id.hasPrefix(prefix) else { return nil }
        let tag = String(id.dropFirst(prefix.count))
        return tag.isEmpty ? nil : tag
    }

    /// Emit-socket path. `DREAMUX_EMIT_SOCKET` (non-empty) is an explicit
    /// override — the parent app reads the same variable it exports to
    /// child shells; otherwise `/tmp/dreamux-emit-<bundleID>.sock`
    /// (`/tmp` because `sun_path` caps at 104 bytes).
    static func emitSocketPath(
        env: [String: String] = ProcessInfo.processInfo.environment,
        bundleID id: String = bundleID()
    ) -> String {
        if let override = env["DREAMUX_EMIT_SOCKET"], !override.isEmpty {
            return override
        }
        return "/tmp/dreamux-emit-\(id).sock"
    }

    /// Per-bundle Application Support dir `<base>/<bundleID>/` — home of
    /// `signals.db`. Caller creates it.
    static func appSupportBundleDir(base: URL, bundleID id: String = bundleID()) -> URL {
        base.appendingPathComponent(id, isDirectory: true)
    }

    /// State dir for `projects.json` / `connections.json` /
    /// `AppStudioData`. Untagged → `<base>/Dreamux` (the legacy literal,
    /// byte-identical to pre-isolation); tagged → `<base>/<bundleID>`,
    /// co-located with that tag's `signals.db` under one deletable folder.
    static func stateDirectory(base: URL, bundleID id: String = bundleID()) -> URL {
        if buildTag(bundleID: id) == nil {
            return base.appendingPathComponent("Dreamux", isDirectory: true)
        }
        return base.appendingPathComponent(id, isDirectory: true)
    }
}
```

- [ ] Step: Run — expect PASS: `swift test --filter BundleIdentityTests` → 12 tests pass.

- [ ] Step: Commit — `git add Sources/Dreamux/BundleIdentity.swift Tests/DreamuxTests/BundleIdentityTests.swift && git commit -m "BundleIdentity: shared per-bundle-id path helper"`

---

### Task 2: Route the emit socket through the helper (env input)

**Files:** Modify `Sources/Dreamux/Signals/SignalEmitSocketServer.swift` (lines 48-54, `defaultSocketPath`); Modify `Tests/DreamuxTests/SignalEmitSocketTests.swift` (append wiring tests).
**Interfaces:** Consumes — `BundleIdentity.emitSocketPath(env:bundleID:)`, `BundleIdentity.baseBundleID` (Task 1). Produces — `SignalEmitSocketServer.defaultSocketPath()` now honors `DREAMUX_EMIT_SOCKET`; `SignalBus.swift:54` and `PTYShellSession.swift:173` inherit the behavior unchanged.

- [ ] Step: Write the failing test — append to `Tests/DreamuxTests/SignalEmitSocketTests.swift`:

```swift
extension SignalEmitSocketTests {
    /// `defaultSocketPath()` is now a thin call-through to the shared
    /// helper: same source of truth that SignalBus binds and
    /// PTYShellSession exports, so bind and export can't drift.
    func testDefaultSocketPathRoutesThroughBundleIdentity() {
        XCTAssertEqual(
            SignalEmitSocketServer.defaultSocketPath(),
            BundleIdentity.emitSocketPath()
        )
    }

    /// Untagged default is byte-identical to today.
    func testDefaultSocketPathUntaggedPin() {
        XCTAssertEqual(
            BundleIdentity.emitSocketPath(env: [:], bundleID: BundleIdentity.baseBundleID),
            "/tmp/dreamux-emit-com.dreamux.Dreamux.sock"
        )
    }
}
```

- [ ] Step: Run it — expect FAIL: `swift test --filter SignalEmitSocketTests/testDefaultSocketPathRoutesThroughBundleIdentity` → passes only if wiring already delegates; before the edit `defaultSocketPath()` ignores `DREAMUX_EMIT_SOCKET`, so if `DREAMUX_EMIT_SOCKET` is set in the test env the two sides diverge and it FAILs with `("/tmp/dreamux-emit-...sock") is not equal to (<override>)`. (Authoritative regression coverage lives in `BundleIdentityTests`; this pins the wiring.)

- [ ] Step: Implement — replace `defaultSocketPath()` in `SignalEmitSocketServer.swift` (lines 47-54):

```swift
    /// Emit-socket path. Delegates to `BundleIdentity` so bind
    /// (`SignalBus`), export (`PTYShellSession`), and the
    /// `DREAMUX_EMIT_SOCKET` override all share one source of truth.
    /// `/tmp` keeps `sun_path` under its 104-byte cap.
    static func defaultSocketPath() -> String {
        BundleIdentity.emitSocketPath()
    }
```

- [ ] Step: Run — expect PASS: `swift test --filter SignalEmitSocketTests` → all pass (existing integration tests + the two new wiring pins).

- [ ] Step: Commit — `git add Sources/Dreamux/Signals/SignalEmitSocketServer.swift Tests/DreamuxTests/SignalEmitSocketTests.swift && git commit -m "Emit socket: honor DREAMUX_EMIT_SOCKET via BundleIdentity"`

---

### Task 3: Route signals.db + projects.json (+ notification id) through the helper

**Files:** Modify `Sources/Dreamux/Signals/SQLiteSignalStore.swift` (lines 91-103, `defaultURL`); Modify `Sources/Dreamux/Models/ProjectStore.swift` (lines 62-81, `stateRootURL`); Modify `Sources/Dreamux/Shell/NotificationManager.swift` (line 29); Modify `Tests/DreamuxTests/SQLiteSignalStoreTests.swift` and `Tests/DreamuxTests/ProjectSessionTests.swift` (append wiring pins) — or a small dedicated test file if those are awkward to extend.
**Interfaces:** Consumes — `BundleIdentity.appSupportBundleDir(base:)`, `.stateDirectory(base:)`, `.bundleID()` (Task 1). Produces — `SQLiteSignalStore.defaultURL()` and `ProjectStore.stateRootURL()` derive per bundle id; `connections.json` / `AppStudioData` follow `stateRootURL` for free.

- [ ] Step: Write the failing test — append to `Tests/DreamuxTests/SQLiteSignalStoreTests.swift`:

```swift
extension SQLiteSignalStoreTests {
    /// The ledger's default lives under the per-bundle-id App Support dir —
    /// wired through BundleIdentity, so a tagged build forks automatically.
    func testDefaultURLIsBundleIDKeyed() throws {
        let url = try SQLiteSignalStore.defaultURL()
        XCTAssertEqual(url.lastPathComponent, "signals.db")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, BundleIdentity.bundleID())
    }
}
```

and append to `Tests/DreamuxTests/ProjectSessionTests.swift` (any `@testable import Dreamux` test target file; it exercises `ProjectStore`):

```swift
extension ProjectSessionTests {
    /// Untagged state dir is the legacy `Dreamux` folder — byte-identical
    /// to pre-isolation. Skipped under the e2e `DREAMUX_STATE_DIR` override.
    func testStateRootUntaggedIsLegacyDreamuxDir() throws {
        try XCTSkipUnless(
            (ProcessInfo.processInfo.environment["DREAMUX_STATE_DIR"] ?? "").isEmpty,
            "DREAMUX_STATE_DIR override active"
        )
        XCTAssertEqual(ProjectStore.stateRootURL().lastPathComponent, "Dreamux")
    }
}
```

- [ ] Step: Run it — expect FAIL: `swift test --filter SQLiteSignalStoreTests/testDefaultURLIsBundleIDKeyed` passes already (db was bundle-id keyed) — this locks in the *helper wiring* so a later refactor can't regress it; `swift test --filter ProjectSessionTests/testStateRootUntaggedIsLegacyDreamuxDir` also passes today (dir is literally `Dreamux`). Both are green-to-green pins that will FAIL if the derivation is later changed to not go through `BundleIdentity`. (If `ProjectSessionTests` is not extensible via `extension`, put both in a new `Tests/DreamuxTests/AppStatePathsTests.swift`.)

- [ ] Step: Implement — three edits.

  `SQLiteSignalStore.swift` `defaultURL()` (lines 91-103):

```swift
    static func defaultURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = BundleIdentity.appSupportBundleDir(base: base)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("signals.db")
    }
```

  `ProjectStore.swift` `stateRootURL()` — replace the `else` branch that built
  `appSupport.appendingPathComponent("Dreamux", …)` (lines 69-78) so the
  `DREAMUX_STATE_DIR` override stays first, then delegate:

```swift
        let appDir: URL
        if let override = env["DREAMUX_STATE_DIR"], !override.isEmpty {
            appDir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let appSupport = (try? fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
            appDir = BundleIdentity.stateDirectory(base: appSupport)
        }
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir
```

  `NotificationManager.swift` line 29 — drop the duplicated literal:

```swift
        let bundleID = BundleIdentity.bundleID()
```

- [ ] Step: Run — expect PASS: `swift test --filter SQLiteSignalStoreTests` and `swift test --filter ProjectSessionTests` → all pass; `swift build` clean.

- [ ] Step: Commit — `git add Sources/Dreamux/Signals/SQLiteSignalStore.swift Sources/Dreamux/Models/ProjectStore.swift Sources/Dreamux/Shell/NotificationManager.swift Tests/DreamuxTests/SQLiteSignalStoreTests.swift Tests/DreamuxTests/ProjectSessionTests.swift && git commit -m "signals.db + projects.json: derive state paths via BundleIdentity"`

---

### Task 4: `make-app.sh` optional tag → stamped Info.plist

**Files:** Modify `Scripts/make-app.sh` (lines 4, 7-9, 24-27; add plist-stamp block after the copy).
**Interfaces:** Consumes — nothing from earlier tasks (bundle assembly). Produces — a tagged `Dreamux-<tag>.app` whose `CFBundleIdentifier` is `com.dreamux.Dreamux.<tag>`, which the Swift helper reads at runtime. Not XCTest-able → manual verification.

- [ ] Step: Write the failing test (manual, pre-change baseline) — run:
  `./Scripts/make-app.sh debug dogfood && plutil -p Dreamux-dogfood.app/Contents/Info.plist | grep CFBundleIdentifier`
  → EXPECT FAIL today: the tag arg is ignored, no `Dreamux-dogfood.app` is produced (build lands in `Dreamux.app`), so the `plutil` target does not exist → `Could not open … No such file or directory`.

- [ ] Step: Implement — edits to `Scripts/make-app.sh`:

  Update the usage comment (line 4) and the arg/APP-path setup (lines 7-11):

```bash
# Usage: ./Scripts/make-app.sh [debug|release] [tag]
#
# With a tag (e.g. `dogfood`) the built bundle gets a unique
# CFBundleIdentifier `com.dreamux.Dreamux.<tag>` and display name
# "Dreamux (<tag>)" stamped into its COPIED Info.plist (the source
# plist is never touched), and lands at Dreamux-<tag>.app so it runs
# side-by-side with an untagged build. Untagged runs are byte-identical
# to before.
set -euo pipefail

CONFIG="${1:-debug}"
TAG="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "$TAG" ]]; then
    APP="$ROOT/Dreamux-$TAG.app"
else
    APP="$ROOT/Dreamux.app"
fi
PLIST="$ROOT/Sources/Dreamux/Resources/Info.plist"
ICON="$ROOT/Sources/Dreamux/Resources/AppIcon.icns"
```

  After the existing `cp "$PLIST" "$APP/Contents/Info.plist"` (line 27), insert:

```bash
# Tagged build: stamp a unique identity into the COPIED plist only —
# the source Info.plist is never mutated. The distinct bundle id is what
# forks signals.db / emit socket / App Support / window-restoration state.
if [[ -n "$TAG" ]]; then
    plutil -replace CFBundleIdentifier  -string "com.dreamux.Dreamux.$TAG" "$APP/Contents/Info.plist"
    plutil -replace CFBundleDisplayName -string "Dreamux ($TAG)"           "$APP/Contents/Info.plist"
    plutil -replace CFBundleName        -string "Dreamux ($TAG)"           "$APP/Contents/Info.plist"
fi
```

- [ ] Step: Run — expect PASS (manual):
  `./Scripts/make-app.sh debug dogfood && plutil -p Dreamux-dogfood.app/Contents/Info.plist | grep -E 'CFBundleIdentifier|CFBundleDisplayName'`
  → EXPECT:
  `"CFBundleIdentifier" => "com.dreamux.Dreamux.dogfood"`
  `"CFBundleDisplayName" => "Dreamux (dogfood)"`
  And confirm the source is untouched:
  `grep -A1 '<key>CFBundleIdentifier</key>' Sources/Dreamux/Resources/Info.plist`
  → `<string>com.dreamux.Dreamux</string>`
  And confirm untagged is byte-identical:
  `./Scripts/make-app.sh debug && plutil -p Dreamux.app/Contents/Info.plist | grep CFBundleIdentifier`
  → `"CFBundleIdentifier" => "com.dreamux.Dreamux"`

- [ ] Step: Commit — `git add Scripts/make-app.sh && git commit -m "make-app.sh: optional tag stamps a unique CFBundleIdentifier"`

---

### Task 5: `dev-dogfood.sh` side-by-side launch

**Files:** Create `Scripts/dev-dogfood.sh`.
**Interfaces:** Consumes — `Scripts/make-app.sh <config> <tag>` producing `Dreamux-<tag>.app` (Task 4). Produces — a one-command side-by-side dogfood launcher. Not XCTest-able → manual verification.

- [ ] Step: Write the failing test (manual, pre-change baseline) — run:
  `./Scripts/dev-dogfood.sh`
  → EXPECT FAIL today: `no such file or directory` (the script does not exist yet).

- [ ] Step: Implement — create `Scripts/dev-dogfood.sh` (and `chmod +x`):

```bash
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
```

- [ ] Step: Run — expect PASS (manual):
  `chmod +x Scripts/dev-dogfood.sh && ./Scripts/dev-dogfood.sh`
  → EXPECT: builds `Dreamux-dogfood.app`, prints `Launched …/Dreamux-dogfood.app side-by-side (tag: dogfood).`, and a second Dreamux window opens alongside the main one. Verify isolation:
  `ls -d ~/Library/Application\ Support/com.dreamux.Dreamux*`
  → both `com.dreamux.Dreamux/` and `com.dreamux.Dreamux.dogfood/` exist;
  `ls /tmp/dreamux-emit-*.sock`
  → both `…com.dreamux.Dreamux.sock` and `…com.dreamux.Dreamux.dogfood.sock` (once each app is running);
  `ls ~/Library/Application\ Support/com.dreamux.Dreamux.dogfood/`
  → contains `signals.db` and `projects.json` (the tag's own state).

- [ ] Step: Commit — `git add Scripts/dev-dogfood.sh && git commit -m "dev-dogfood.sh: build + launch a tagged instance side-by-side"`
