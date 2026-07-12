# Window Chrome Interactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the hidden titlebar's standard behaviors on the custom chrome — drag-to-move from non-interactive chrome and double-click-to-zoom (toggle), honoring the user's macOS double-click setting.

**Architecture:** One `NSEvent` local mouse-down monitor installed at launch. It hit-tests each click; clicks on controls/text/scrollers/list rows pass through untouched. Chrome clicks (the 40pt top strip, or a native list's empty body — the projects rail) start `performDrag` on single click and perform the titlebar double-click action on double click.

**Tech Stack:** Swift 6 / AppKit + SwiftUI (macOS 14 floor), SwiftPM, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-12-window-chrome-interactions-design.md`

## Global Constraints

- macOS 14 floor; no new dependencies; XCTest in `Tests/DreamuxTests`; executable target never links XCTest.
- The monitor must never act on: `NSControl`, `NSText`/`NSTextView`, `NSScroller`, `NSTableRowView` (or any view whose ancestry up to the frame view contains one), non-titled windows, or sheets.
- Double-click maps `AppleActionOnDoubleClick`: `"Minimize"` → miniaturize, `"None"` → nothing, everything else (nil/"Maximize"/"Fill"/junk) → `performZoom` (never fullscreen).
- Installs unconditionally (also in e2e mode — the driver never synthesizes mouse events, so scenarios are unaffected; the full e2e suite is the regression gate).
- Commit style `Prefix: summary`; stage ONLY named files; never touch `.claude/worktrees/`.

---

### Task 1: WindowChromeInteractions monitor

**Files:**
- Create: `Sources/Dreamux/Shell/WindowChromeInteractions.swift`
- Modify: `Sources/Dreamux/DreamuxApp.swift` (`DreamuxApp.init`, after the `SignalBus` touch)
- Test: `Tests/DreamuxTests/TitlebarDoubleClickActionTests.swift`

**Interfaces:**
- Consumes: nothing project-specific.
- Produces: `TitlebarDoubleClickAction.from(defaultsValue: String?) -> TitlebarDoubleClickAction`; `WindowChromeInteractions.install()` (idempotent, `@MainActor`).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/DreamuxTests/TitlebarDoubleClickActionTests.swift
import XCTest
@testable import Dreamux

final class TitlebarDoubleClickActionTests: XCTestCase {
    func testMinimizeMapsToMinimize() {
        XCTAssertEqual(TitlebarDoubleClickAction.from(defaultsValue: "Minimize"), .minimize)
    }

    func testNoneMapsToNone() {
        XCTAssertEqual(TitlebarDoubleClickAction.from(defaultsValue: "None"), TitlebarDoubleClickAction.none)
    }

    func testNilDefaultsToZoom() {
        XCTAssertEqual(TitlebarDoubleClickAction.from(defaultsValue: nil), .zoom)
    }

    func testMaximizeMapsToZoom() {
        XCTAssertEqual(TitlebarDoubleClickAction.from(defaultsValue: "Maximize"), .zoom)
    }

    func testFillMapsToZoom() {
        XCTAssertEqual(TitlebarDoubleClickAction.from(defaultsValue: "Fill"), .zoom)
    }

    func testUnrecognizedValueMapsToZoom() {
        XCTAssertEqual(TitlebarDoubleClickAction.from(defaultsValue: "garbage-42"), .zoom)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TitlebarDoubleClickActionTests 2>&1 | tail -10`
Expected: compile error — `TitlebarDoubleClickAction` not found.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Dreamux/Shell/WindowChromeInteractions.swift
import AppKit

/// The titlebar double-click action from System Settings › Desktop & Dock.
enum TitlebarDoubleClickAction: Equatable {
    case zoom, minimize, none

    /// Maps the "AppleActionOnDoubleClick" defaults string. Unset or
    /// unrecognized values fall back to zoom — macOS's own default.
    static func from(defaultsValue: String?) -> TitlebarDoubleClickAction {
        switch defaultsValue {
        case "Minimize": .minimize
        case "None": TitlebarDoubleClickAction.none
        default: .zoom
        }
    }
}

/// Restores the hidden titlebar's standard behaviors on the custom
/// chrome: dragging non-interactive chrome moves the window and
/// double-clicking it zooms (or minimizes, per the user's macOS
/// setting). One window-level mouse-down monitor rather than per-view
/// drag handlers — the projects rail is a native List whose empty body
/// swallows clicks, so no view-level handler can cover it, and
/// representable hit-testing has burned this app before (see spec).
@MainActor
enum WindowChromeInteractions {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            handle(event) ? nil : event
        }
    }

    private enum Classification { case interactive, chrome, content }

    /// True when the event was consumed as a chrome interaction.
    private static func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window,
              window.styleMask.contains(.titled),
              !window.isSheet,
              let frameView = window.contentView?.superview else { return false }
        let point = frameView.convert(event.locationInWindow, from: nil)
        guard let hit = frameView.hitTest(point) else { return false }
        guard classify(hit: hit, event: event, window: window, boundary: frameView) == .chrome else {
            return false
        }

        if event.clickCount >= 2 {
            switch TitlebarDoubleClickAction.from(
                defaultsValue: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            ) {
            case .zoom: window.performZoom(nil)
            case .minimize: window.performMiniaturize(nil)
            case .none: break
            }
        } else {
            window.performDrag(with: event)
        }
        return true
    }

    /// Walks the hit view's ancestry: controls, text, scrollers, and
    /// list rows keep their clicks. A native list's EMPTY body is the
    /// one exception — NSTableView is an NSControl subclass, but a click
    /// landing below the last row (row(at:) == -1) hits no row and is
    /// chrome, not interaction; the table check must therefore precede
    /// the control check. Non-interactive hits are chrome only in the
    /// 40pt top strip (window coordinates are bottom-origin).
    private static func classify(
        hit: NSView, event: NSEvent, window: NSWindow, boundary: NSView
    ) -> Classification {
        var current: NSView? = hit
        while let candidate = current, candidate !== boundary {
            if let table = candidate as? NSTableView {
                let local = table.convert(event.locationInWindow, from: nil)
                return table.row(at: local) == -1 ? .chrome : .interactive
            }
            if candidate is NSControl || candidate is NSText
                || candidate is NSScroller || candidate is NSTableRowView {
                return .interactive
            }
            current = candidate.superview
        }
        if event.locationInWindow.y >= window.frame.height - 40 { return .chrome }
        return .content
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TitlebarDoubleClickActionTests 2>&1 | tail -5`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Install at launch**

In `Sources/Dreamux/DreamuxApp.swift`, in `DreamuxApp.init()` directly after `_ = SignalBus.shared`:

```swift
// Standard titlebar behaviors on the custom chrome (drag + double-click
// zoom) — .hiddenTitleBar removes them; this puts them back app-wide.
WindowChromeInteractions.install()
```

- [ ] **Step 6: Build + full regression + e2e**

Run: `swift build 2>&1 | tail -3` → `Build complete!`
Run: `swift test 2>&1 | tail -3` → 0 failures.
Run: `Scripts/e2e/run-e2e.sh 2>&1 | tail -20` → exit 0, all scenarios PASS (the monitor must not disturb any scenario). If an unrelated scenario fails, retry once; twice → DONE_WITH_CONCERNS with the log tail. If the app won't launch because another Dreamux instance is running, STOP and report BLOCKED — never kill a running Dreamux.

- [ ] **Step 7: Commit**

```bash
git add Sources/Dreamux/Shell/WindowChromeInteractions.swift Sources/Dreamux/DreamuxApp.swift Tests/DreamuxTests/TitlebarDoubleClickActionTests.swift
git commit -m "Chrome: window-level drag + double-click zoom on non-interactive chrome"
```

---

## Verification (after the task)

- Manual (relaunched app): drag from the top strip; drag from the rail's empty body; double-click both → zoom toggle (grow, then restore); rows still select; buttons click; terminal selection unaffected; sheets unaffected.
