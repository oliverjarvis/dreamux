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
