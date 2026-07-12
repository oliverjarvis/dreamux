import AppKit
import XCTest
@testable import Dreamux

/// Real-hierarchy coverage for `WindowChromeInteractions.classify` — a
/// separate file from `TitlebarDoubleClickActionTests` because that file
/// covers the double-click → zoom/minimize/none *mapping*, a pure-value
/// concern, while this exercises `classify`'s AppKit hit-test geometry
/// against actual `NSWindow`/`NSView` instances built offscreen (never
/// ordered onscreen — no window server round trip needed for hit-testing
/// or geometry queries).
///
/// `classify` is `internal` (see its doc comment in
/// `WindowChromeInteractions.swift`) specifically so this file can call it
/// directly instead of driving it through synthetic `NSEvent`s, and takes
/// a raw `locationInWindow: NSPoint` rather than an `NSEvent` for the same
/// reason — `NSEvent.mouseEvent(...)` construction is awkward and adds
/// nothing a plain point doesn't already cover.
@MainActor
final class WindowChromeClassifyTests: XCTestCase {
    /// A real titled `NSWindow` plus the same "boundary" view
    /// `WindowChromeInteractions.handle` resolves in production
    /// (`window.contentView!.superview!`, the window's root theme-frame
    /// view) — subviews added directly to it sit in the window's own
    /// base coordinate space, matching `NSEvent.locationInWindow`.
    private func makeWindow(width: CGFloat = 400, height: CGFloat = 400) -> (window: NSWindow, boundary: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        return (window, window.contentView!.superview!)
    }

    // MARK: - NSControl exclusion

    func testButtonHitIsInteractive() {
        let (window, boundary) = makeWindow()
        let button = NSButton(frame: NSRect(x: 20, y: 20, width: 80, height: 24))
        boundary.addSubview(button)
        let point = NSPoint(x: 40, y: 30)
        let hit = boundary.hitTest(point)!
        XCTAssertEqual(
            WindowChromeInteractions.classify(
                hit: hit, locationInWindow: point, window: window, boundary: boundary),
            .interactive)
    }

    // MARK: - NSTableView: empty vs. one row

    private final class OneRowDataSource: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 1 }
    }

    func testEmptyTableHitIsChrome() {
        let (window, boundary) = makeWindow()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col")))
        boundary.addSubview(table)
        let point = NSPoint(x: 50, y: 50)
        let hit = boundary.hitTest(point)!
        XCTAssertEqual(
            WindowChromeInteractions.classify(
                hit: hit, locationInWindow: point, window: window, boundary: boundary),
            .chrome)
    }

    /// Content-area lists (file tree, signals log, diff rail) are not
    /// flush against the window's left edge; their empty tail must NOT be
    /// classified as chrome, unlike the left-edge-sidebar case above.
    func testEmptyTableAwayFromLeftEdgeIsNotChrome() {
        let (window, boundary) = makeWindow()
        let table = NSTableView(frame: NSRect(x: 300, y: 0, width: 200, height: 300))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col")))
        boundary.addSubview(table)
        let point = NSPoint(x: 350, y: 50)
        let hit = boundary.hitTest(point)!
        XCTAssertNotEqual(
            WindowChromeInteractions.classify(
                hit: hit, locationInWindow: point, window: window, boundary: boundary),
            .chrome)
    }

    func testTableWithOneRowHitAtRowIsInteractive() {
        let (window, boundary) = makeWindow()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col")))
        let dataSource = OneRowDataSource()
        table.dataSource = dataSource
        table.reloadData()
        boundary.addSubview(table)

        let rowRect = table.rect(ofRow: 0)
        XCTAssertFalse(rowRect.isEmpty, "reloadData() should have registered one row")
        let localPoint = NSPoint(x: rowRect.midX, y: rowRect.midY)
        let point = table.convert(localPoint, to: nil)
        let hit = boundary.hitTest(point)!
        XCTAssertEqual(
            WindowChromeInteractions.classify(
                hit: hit, locationInWindow: point, window: window, boundary: boundary),
            .interactive)
    }

    // MARK: - Plain NSView: strip vs. content, and the rail's x-bound

    func testPlainViewBelowStripIsContent() {
        let (window, boundary) = makeWindow()
        let plain = NSView(frame: NSRect(x: 0, y: 0, width: window.frame.width, height: window.frame.height))
        boundary.addSubview(plain)
        // Well below the 30pt strip regardless of x.
        let point = NSPoint(x: 100, y: 100)
        let hit = boundary.hitTest(point)!
        XCTAssertEqual(
            WindowChromeInteractions.classify(
                hit: hit, locationInWindow: point, window: window, boundary: boundary),
            .content)
    }

    func testPlainViewInStripOverRailColumnIsChrome() {
        let (window, boundary) = makeWindow()
        let plain = NSView(frame: NSRect(x: 0, y: 0, width: window.frame.width, height: window.frame.height))
        boundary.addSubview(plain)
        // 5pt below the physical top, x = 50 — inside the rail's 210pt
        // column, same zone the projects rail's Search-button spacer
        // occupies.
        let point = NSPoint(x: 50, y: window.frame.height - 5)
        let hit = boundary.hitTest(point)!
        XCTAssertEqual(
            WindowChromeInteractions.classify(
                hit: hit, locationInWindow: point, window: window, boundary: boundary),
            .chrome)
    }

    /// Same top-strip y as the previous case, but x is past the rail's
    /// column — this is exactly the point that misclassified the content
    /// card's header controls (e.g. `HeaderRunControls`) as chrome under
    /// the old full-width 40pt strip; the fix bounds the strip to the
    /// rail's x-range instead of shrinking it for the whole window.
    func testPlainViewInStripPastRailColumnIsContent() {
        let (window, boundary) = makeWindow()
        let plain = NSView(frame: NSRect(x: 0, y: 0, width: window.frame.width, height: window.frame.height))
        boundary.addSubview(plain)
        let point = NSPoint(x: 300, y: window.frame.height - 5)
        let hit = boundary.hitTest(point)!
        XCTAssertEqual(
            WindowChromeInteractions.classify(
                hit: hit, locationInWindow: point, window: window, boundary: boundary),
            .content)
    }
}
