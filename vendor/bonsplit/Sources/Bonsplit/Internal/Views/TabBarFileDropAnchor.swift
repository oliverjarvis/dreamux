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
struct TabBarFileDropAnchor: NSViewRepresentable {
    let onFileDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onFileDrop = onFileDrop
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        // The closure captures `pane.id` from the SwiftUI body that
        // constructed it; refresh it on every update so a stale pane
        // id from an earlier body evaluation never lingers.
        nsView.onFileDrop = onFileDrop
    }
}

/// Owns a window-level `FileDropOverlayView` frame-synced to this
/// view's bounds. See `TabBarFileDropAnchor`'s doc comment for why an
/// overlay is needed instead of a SwiftUI drop modifier.
final class AnchorView: NSView {
    var onFileDrop: (([URL]) -> Void)?
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
        canReadFileURLs(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL],
            !urls.isEmpty
        else { return false }
        DispatchQueue.main.async { [anchor] in
            anchor?.onFileDrop?(urls)
        }
        return true
    }

    private func canReadFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
    }
}
