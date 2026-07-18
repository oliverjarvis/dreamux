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

    /// `internal`, not `private`: it's `classify`'s return type, and
    /// `classify` itself needs `internal` visibility for
    /// `WindowChromeClassifyTests` (see that function's doc comment).
    enum Classification { case interactive, chrome, content }

    /// True when the event was consumed as a chrome interaction.
    private static func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window,
              window.styleMask.contains(.titled),
              !window.isSheet,
              let frameView = window.contentView?.superview else { return false }
        // `hitTest(_:)` is documented to take a point in the RECEIVER'S
        // SUPERVIEW's coordinate space. `frameView` (== window.contentView's
        // superview) IS the window's theme frame — the hierarchy's root
        // view, with no superview of its own — so its coordinate space is
        // already the window's base coordinate space, exactly what
        // `event.locationInWindow` is expressed in; no conversion needed.
        guard let hit = frameView.hitTest(event.locationInWindow) else { return false }
        guard classify(
            hit: hit, locationInWindow: event.locationInWindow, window: window, boundary: frameView
        ) == .chrome else {
            return false
        }

        // A native titlebar click activates the window; consuming the event
        // bypasses that, so restore it explicitly.
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }

        if event.clickCount >= 2 {
            switch TitlebarDoubleClickAction.from(
                defaultsValue: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            ) {
            case .zoom: if window.styleMask.contains(.resizable) { window.performZoom(nil) }
            case .minimize: if window.styleMask.contains(.miniaturizable) { window.performMiniaturize(nil) }
            case .none: break
            }
        } else {
            window.performDrag(with: event)
        }
        return true
    }

    /// Height of the top chrome strip, and how far across the window it
    /// reaches — see `railStripXBound` for why it's bounded to the rail
    /// column rather than spanning the full width.
    ///
    /// Derived from the tighter of the two projects-rail states' first
    /// interactive control:
    ///   - expanded rail (`ProjectsRail.swift`): a `Color.clear.frame
    ///     (height: 30)` spacer (zero `VStack` spacing) precedes the
    ///     Search button, so its top edge sits at y = 30.
    ///   - collapsed stub (`ContentView.collapsedRailStub`): a
    ///     `Color.clear.frame(height: 26)` spacer plus 10pt of `VStack`
    ///     spacing precedes `railToggle`, so its top edge sits at y = 36.
    /// 30 clears both (with the collapsed stub keeping a 6pt margin), and
    /// `classify` uses a strict comparison (`y > H − 30`, i.e.
    /// distance-from-top strictly under 30pt) below so a click landing
    /// exactly on the Search button's top pixel (y == 30) still resolves
    /// as interactive, not chrome.
    private static let topStripHeight: CGFloat = 30

    /// The x-range the top strip is limited to: the projects rail's
    /// column, not the full window width.
    ///
    /// Plain SwiftUI `Button`s never appear as `NSControl` in AppKit's
    /// hit-test tree — they resolve to the enclosing `NSHostingView` — so
    /// `classify`'s `NSControl` exclusion below can't protect them, and
    /// every clickable control in this app is a SwiftUI `Button`. That
    /// rules out a full-width strip: `ContentView.contextHeaderRow` (the
    /// content card's header) centers its 26pt-tall `HeaderRunControls`
    /// pill in a 44pt-tall row, 9pt of top margin — and that row sits
    /// flush against the window's physical top edge whenever the user
    /// picks Settings → Appearance → "Flush" edge padding
    /// (`AppearanceSettings.edgeInsetsKey`, `ContentView`'s `edgeInsets`
    /// toggle — default is "Inset", but it's a live, user-facing radio
    /// button, not dead code). That leaves the run-controls pill's top
    /// edge just 9pt from the window top — no strip height both wide
    /// enough to be useful and short enough to clear it exists. So
    /// instead of shrinking the strip for the whole window, it's bounded
    /// to the one column with real headroom: the projects rail. 210 is
    /// the *expanded* rail's fixed width (`ContentView.mainStack`'s
    /// `.frame(width: 210)`); the collapsed stub is narrower (76), so
    /// bounding to 210 safely covers both rail states without needing to
    /// know which one is showing.
    ///
    /// `ContentView.projectHeaderRow` (the work-items column's header,
    /// which starts at the collapsed stub's x = 76) also has a doc
    /// comment cross-referencing this bound — see that declaration.
    private static let railStripXBound: CGFloat = 210

    /// Walks the hit view's ancestry: controls, text, scrollers, and
    /// list rows keep their clicks. A native list's EMPTY body is the
    /// one exception — NSTableView is an NSControl subclass, but a click
    /// landing below the last row (row(at:) == -1) hits no row and is
    /// chrome, not interaction; the table check must therefore precede
    /// the control check. That empty-body rule only fires for tables
    /// flush against the window's left edge (the projects rail, the
    /// Settings sidebar) — a content-area list (file tree, signals log,
    /// diff rail) also has an empty tail below its last row, and clicks
    /// there must stay ordinary. Non-interactive hits are chrome only in
    /// the top strip, and only above the projects rail's column — see
    /// `topStripHeight`/`railStripXBound` for why the strip can't safely
    /// span the full window width. `internal` (not `private`) so
    /// `WindowChromeClassifyTests` can exercise it directly against real
    /// AppKit hierarchies. Takes the raw point rather than the `NSEvent`
    /// so tests don't need to synthesize one.
    static func classify(
        hit: NSView, locationInWindow: NSPoint, window: NSWindow, boundary: NSView
    ) -> Classification {
        var current: NSView? = hit
        while let candidate = current, candidate !== boundary {
            if let table = candidate as? NSTableView {
                // Only left-edge sidebars are chrome (the projects rail, the Settings
                // sidebar). Content-area lists — file tree, signals log, diff rail —
                // also hit row(at:) == -1 below their last row, and those clicks must
                // stay ordinary.
                guard table.convert(NSPoint.zero, to: nil).x < 1 else { return .interactive }
                let local = table.convert(locationInWindow, from: nil)
                return table.row(at: local) == -1 ? .chrome : .interactive
            }
            if candidate is NSControl || candidate is NSText
                || candidate is NSScroller || candidate is NSTableRowView {
                return .interactive
            }
            current = candidate.superview
        }
        // AppKit's edge resize bands overlap the top strip: a mouse-down
        // within a few points of the window's top or left edge is a
        // resize grab (top edge, or the top-left corner diagonal), and
        // consuming it to `performDrag` breaks resizing — the window
        // moves instead. Leave those points to the frame's resize
        // machinery.
        if window.styleMask.contains(.resizable) {
            let resizeBand: CGFloat = 6
            if locationInWindow.y > window.frame.height - resizeBand
                || locationInWindow.x < resizeBand {
                return .content
            }
        }
        if locationInWindow.x <= railStripXBound,
           locationInWindow.y > window.frame.height - topStripHeight {
            return .chrome
        }
        return .content
    }
}
