import AppKit
import GhosttyTerminal
import os

/// Finds whichever Ghostty terminal NSView is currently visible in the
/// key window and makes it the first responder, so keystrokes flow
/// straight in without the user having to click into the pane.
///
/// Bonsplit's `selectTab` only updates its own internal state; nothing
/// touches AppKit's responder chain, so a freshly-created tab sits
/// inert until clicked. We call this after createTab/splitPane/
/// selectTab to wire focus back up. With `keepAllAlive` lifecycle
/// every tab's NSView is present in the hierarchy — only one is
/// effectively visible (its ancestors all have non-zero opacity), so
/// we filter to that one.
@MainActor
enum TerminalFocus {
    private static let logger = Logger(
        subsystem: "com.dreamux.Dreamux",
        category: "TerminalFocus"
    )

    /// Defers to the next runloop so SwiftUI has time to lay out the
    /// newly-selected tab before we go hunting for its NSView.
    static func focusVisibleTerminal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            attemptFocus()
        }
    }

    private static func attemptFocus() {
        // `NSApplication.shared` (not the `NSApp` global) — `NSApp` stays
        // nil until something reads `.shared`, which never happens in a
        // headless `swift test` process (no app lifecycle runs), so
        // `NSApp.keyWindow` would force-unwrap a nil `NSApp` and crash.
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else {
            logger.info("no key window")
            return
        }
        guard let content = window.contentView else {
            logger.info("key window has no contentView")
            return
        }

        var terminals: [AppTerminalView] = []
        collectTerminals(in: content, into: &terminals)

        if terminals.isEmpty {
            logger.info("no AppTerminalView found in window tree")
            return
        }

        let visible = terminals.filter { isEffectivelyVisible($0) }
        logger.info("\(terminals.count, privacy: .public) terminal(s), \(visible.count, privacy: .public) visible")

        // Among visible candidates pick the topmost in z-order (later in
        // a SwiftUI ZStack draws on top — DFS appends in source order, so
        // the last appended is on top).
        let target = visible.last ?? terminals.last
        guard let target else { return }
        let result = window.makeFirstResponder(target)
        logger.info("makeFirstResponder=\(result, privacy: .public) on \(ObjectIdentifier(target).debugDescription, privacy: .public)")
    }

    private static func collectTerminals(in root: NSView, into out: inout [AppTerminalView]) {
        if let terminal = root as? AppTerminalView {
            out.append(terminal)
        }
        for sub in root.subviews {
            collectTerminals(in: sub, into: &out)
        }
    }

    /// Walks the ancestor chain looking for any node SwiftUI has marked
    /// invisible. Both `NSView.alphaValue` and the backing `CALayer.opacity`
    /// are checked because SwiftUI's `.opacity(_:)` modifier targets the
    /// layer, while `.hidden()` flips `isHidden`.
    private static func isEffectivelyVisible(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v.isHidden { return false }
            if v.alphaValue < 0.5 { return false }
            if let layer = v.layer, layer.opacity < 0.5 { return false }
            current = v.superview
        }
        return view.window != nil
    }
}
