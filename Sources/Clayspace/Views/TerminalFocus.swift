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
/// selectTab to wire focus back up.
@MainActor
enum TerminalFocus {
    private static let logger = Logger(
        subsystem: "com.clayspace.Clayspace",
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
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
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

        // Pick the first one we can hand focus to. AppKit's
        // makeFirstResponder returns false if the view rejects (which is
        // typically the case for off-screen/hidden Ghostty surfaces).
        for terminal in terminals {
            if window.makeFirstResponder(terminal) {
                logger.info("focused terminal — \(terminal.classForCoder, privacy: .public)")
                return
            }
        }

        logger.info("\(terminals.count, privacy: .public) terminal(s) found, none accepted firstResponder")
    }

    private static func collectTerminals(in root: NSView, into out: inout [AppTerminalView]) {
        if let terminal = root as? AppTerminalView {
            out.append(terminal)
        }
        for sub in root.subviews {
            collectTerminals(in: sub, into: &out)
        }
    }
}
