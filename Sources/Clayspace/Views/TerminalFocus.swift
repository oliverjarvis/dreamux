import AppKit

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
    /// Defers to the next runloop so SwiftUI has time to lay out the
    /// newly-selected tab before we go hunting for its NSView.
    static func focusVisibleTerminal() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow,
                  let content = window.contentView else { return }
            guard let view = visibleTerminalView(in: content) else { return }
            window.makeFirstResponder(view)
        }
    }

    /// AppTerminalView lives in GhosttyTerminal — match by class-name
    /// suffix instead of importing it directly so this helper stays
    /// tolerant of the surrounding module structure.
    private static func visibleTerminalView(in root: NSView) -> NSView? {
        if root.className.hasSuffix("AppTerminalView"),
           !isEffectivelyHidden(root) {
            return root
        }
        for sub in root.subviews {
            if let found = visibleTerminalView(in: sub) {
                return found
            }
        }
        return nil
    }

    private static func isEffectivelyHidden(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v.isHidden { return true }
            if let layer = v.layer, layer.opacity < 0.99 { return true }
            current = v.superview
        }
        return false
    }
}
