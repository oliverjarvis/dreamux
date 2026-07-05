import SwiftUI
import AppKit

/// Window-level file-drop target for a pane's tab bar.
///
/// Why an overlay instead of a SwiftUI drop modifier: SwiftUI's
/// platform-view host blocks drag-destination routing into its
/// subtree -- both `registerForDraggedTypes` on views inside it and
/// `.dropDestination`/`.onDrop` on the SwiftUI side go silent for
/// regions inside such a host (verified empirically across three
/// attempts on this exact tab bar). The only reliable drop target is
/// a view OUTSIDE that subtree, so this keeps a transparent,
/// click-through sibling of the window's content view frame-synced
/// over the tab bar's exact rect. Mirrors Dreamux's
/// `HostedTerminalView.swift` (`TerminalDropContainer`/
/// `TerminalDropOverlay`), which established this pattern for the
/// terminal surface and is user-verified working; see that file's doc
/// comment for the fuller empirical account.
///
/// Unlike the terminal overlay, this needs no selection gating: a
/// pane's tab bar is unique to that pane and is visible exactly when
/// the pane itself is. It is not inside the `keepAllAlive` per-tab
/// content `ZStack` that keeps offstage tabs mounted at the same
/// frame -- there's no "shadow" bar competing for the same window
/// rect, so window/hidden-ancestor checks alone are a sufficient gate.
///
/// This anchor reports two things to the SwiftUI side, rather than
/// drawing any feedback itself: the drag's live x-position
/// (`onHoverX`, anchor-local, nil when not hovering) so `TabBarView`
/// can drive its own insertion-point indicator -- the same one
/// tab-reordering uses -- and the drop itself (`onDropAtX`) carrying
/// the x-position the drop resolved at, so the host can map it to the
/// same insertion index the indicator was showing.
struct TabBarFileDropAnchor: NSViewRepresentable {
    let onHoverX: (CGFloat?) -> Void
    let onDropAtX: ([URL], CGFloat) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onHoverX = onHoverX
        view.onDropAtX = onDropAtX
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        // The closures capture `pane.id` (and local state) from the
        // SwiftUI body that constructed them; refresh both on every
        // update so stale captures from an earlier body evaluation
        // never linger.
        nsView.onHoverX = onHoverX
        nsView.onDropAtX = onDropAtX
    }
}

/// Owns a window-level `FileDropOverlayView` frame-synced to this
/// view's bounds. See `TabBarFileDropAnchor`'s doc comment for why an
/// overlay is needed instead of a SwiftUI drop modifier.
final class AnchorView: NSView {
    var onHoverX: ((CGFloat?) -> Void)?
    var onDropAtX: (([URL], CGFloat) -> Void)?
    private var overlay: FileDropOverlayView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncOverlay()
    }

    override func viewDidHide() {
        super.viewDidHide()
        syncOverlay()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncOverlay()
    }

    override func layout() {
        super.layout()
        syncOverlay()
    }

    /// Create/position the overlay while this view is parented in a
    /// window and visible; tear it down otherwise (pane hidden by a
    /// split collapsing, tab bar unparented). No selection gating --
    /// see the type's doc comment.
    private func syncOverlay() {
        guard let window, let host = window.contentView,
              !isHiddenOrHasHiddenAncestor else {
            overlay?.removeFromSuperview()
            overlay = nil
            return
        }
        let target = overlay ?? {
            let fresh = FileDropOverlayView()
            fresh.anchor = self
            overlay = fresh
            return fresh
        }()
        if target.superview !== host {
            host.addSubview(target, positioned: .above, relativeTo: nil)
        }
        target.frame = convert(bounds, to: host)
    }
}

/// Transparent, click-through drop target parented at window level --
/// outside the SwiftUI platform-view subtree that swallows drag
/// routing. `hitTest` returns nil so every mouse event (including tab
/// clicks and drags) passes through to the bar beneath; drag-
/// destination discovery goes by registered types, which is exactly
/// the one signal we want to catch here.
///
/// Draws nothing itself -- the drop-target feedback is the same blue
/// insertion-point indicator tab-reordering uses, rendered by
/// `TabBarView` from the x-position this view reports via
/// `AnchorView.onHoverX`/`onDropAtX`.
final class FileDropOverlayView: NSView {
    weak var anchor: AnchorView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let readable = canReadFileURLs(sender)
        if readable {
            reportHoverX(sender)
        }
        return readable ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let readable = canReadFileURLs(sender)
        if readable {
            reportHoverX(sender)
        } else {
            anchor?.onHoverX?(nil)
        }
        return readable ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        anchor?.onHoverX?(nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        anchor?.onHoverX?(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL],
            !urls.isEmpty
        else {
            anchor?.onHoverX?(nil)
            return false
        }
        let x = localX(for: sender)
        anchor?.onHoverX?(nil)
        DispatchQueue.main.async { [anchor] in
            anchor?.onDropAtX?(urls, x)
        }
        return true
    }

    private func reportHoverX(_ sender: NSDraggingInfo) {
        anchor?.onHoverX?(localX(for: sender))
    }

    /// `draggingLocation` is in the window's base coordinate system;
    /// convert to this view's local coordinates. Since this overlay's
    /// frame is kept frame-synced 1:1 with the anchor's bounds (see
    /// `AnchorView.syncOverlay`), the resulting x is exactly the
    /// anchor-local x `TabBarView` needs.
    private func localX(for sender: NSDraggingInfo) -> CGFloat {
        convert(sender.draggingLocation, from: nil).x
    }

    private func canReadFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
    }
}
