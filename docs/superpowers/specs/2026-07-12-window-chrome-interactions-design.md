# Window Chrome Interactions (drag + double-click zoom) — Design

**Date:** 2026-07-12
**Status:** Approved (brainstorm complete)

## Problem

The app hides the system titlebar (`.hiddenTitleBar`) and draws its own
chrome, but never re-implemented the titlebar's standard behaviors: you
cannot drag the window from non-button chrome (the top strip, the projects
rail's empty body), and double-clicking chrome does not zoom the window.
Both are baseline macOS expectations.

## Decisions made during brainstorming

- **Approach: one window-level `NSEvent` local monitor** (approved over
  per-zone drag representables — the rail is a native `List` whose empty
  body swallows clicks, and representable subtrees have caused hit-test
  pain in this app before; see the platform-view drop-blocking history).
- Double-click performs the **titlebar action from System Settings**
  (`AppleActionOnDoubleClick`): "Minimize" → miniaturize, "None" →
  nothing, anything else (Maximize/Fill/unset) → `performZoom` — the
  grow/restore toggle the user asked for. Never fullscreen.

## 1. Component

New file `Sources/Dreamux/Shell/WindowChromeInteractions.swift`:

- `enum TitlebarDoubleClickAction { case zoom, minimize, none }` with
  `static func from(defaultsValue: String?) -> TitlebarDoubleClickAction`
  — pure mapping: `"Minimize"` → `.minimize`, `"None"` → `.none`,
  everything else (including nil, `"Maximize"`, `"Fill"`) → `.zoom`.
- `@MainActor enum WindowChromeInteractions` with `static func install()`
  — installs a `.leftMouseDown` local monitor once (idempotent via a
  static flag). Called from `DreamuxApp.init` after the existing
  `SignalBus` touch. Skipped in e2e mode? **No** — it must not interfere
  with e2e (monitors only act on chrome clicks; the driver never
  synthesizes mouse events), so it installs unconditionally.

## 2. Monitor behavior

For each left mouse-down:

1. **Window filter:** the event's window must be titled
   (`styleMask.contains(.titled)`), not a sheet (`isSheet == false`), and
   have a content view. Otherwise pass the event through.
2. **Hit test:** `window.contentView?.superview?.hitTest(...)` at the
   event location (the frame view catches the full window including the
   transparent titlebar strip).
3. **Interactive exclusion:** walk from the hit view up to the frame
   view; if any view is an `NSControl`, `NSText`/`NSTextView`,
   `NSScroller`, or an `NSTableRowView` — pass the event through. (This
   keeps buttons, fields, list rows, scrollers, and the Ghostty terminal
   untouched; the terminal's view is none of these but is also never in a
   chrome zone.)
4. **Chrome-zone test** — the click is chrome when either:
   - **Top strip:** `event.locationInWindow.y >= window.frame.height - 40`
     (window coordinates are bottom-origin; 40pt covers the traffic-light
     row and the header's dead space; header *controls* are already
     excluded by step 3), or
   - **Empty native-list body:** the hit view is an `NSTableView` (or its
     clip view resolves to one) and `tableView.row(at: point) == -1` — in
     the project window that is exactly the projects rail below its last
     row; in Applet Studio, its own list's empty body.
   Otherwise pass the event through.
5. **Act:**
   - `clickCount >= 2` → perform `TitlebarDoubleClickAction.from(
     UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick"))`:
     `.zoom` → `window.performZoom(nil)`, `.minimize` →
     `window.performMiniaturize(nil)`, `.none` → nothing. Swallow the
     event (return nil).
   - Single click → `window.performDrag(with: event)`, swallow the event.

Sequencing note: the first click of a double-click starts a drag that ends
harmlessly on mouse-up; the second click arrives with `clickCount == 2`
and triggers the action — the same feel as a real titlebar.

## 3. Testing

- Unit tests for `TitlebarDoubleClickAction.from` (nil / "Maximize" /
  "Fill" / "Minimize" / "None" / arbitrary junk).
- Full unit suite + e2e suite as regression (the monitor must not disturb
  any existing scenario — none of them synthesize chrome clicks).
- Manual verification (mouse simulation is outside the e2e harness):
  drag from the top strip, drag from the rail's empty body, double-click
  both → zoom toggle; confirm rows still select, buttons still click,
  terminal focus/selection unaffected, sheet interactions unaffected.

## Out of scope

- Drag/zoom from panel-card headers deeper in the window (beyond the
  40pt top strip).
- macOS 15 `WindowDragGesture` adoption (floor is 14).
- Any change to `isMovableByWindowBackground` (the monitor covers the
  approved zones; the flag's SwiftUI interactions are unpredictable).
