import SwiftUI
import AppKit
import GhosttyTerminal

/// Hosts a session-owned terminal NSView (see `TabSession.terminalView`).
/// Replaces the package's `TerminalSurfaceView`, which creates a fresh
/// NSView (and therefore a fresh, empty ghostty surface) on every mount —
/// this parents the same live instance wherever the tab is rendered, so
/// unmount/remount cycles keep the terminal's contents.
struct HostedTerminalView: View {
    @Environment(\.colorScheme) private var colorScheme

    let session: TabSession

    var body: some View {
        HostedTerminalRepresentable(session: session)
            .background(.clear)
            // Same light/dark adoption `TerminalSurfaceView` performs.
            .onChange(of: colorScheme, initial: true) {
                session.viewState.adopt(colorScheme: colorScheme)
            }
    }
}

private struct HostedTerminalRepresentable: NSViewRepresentable {
    let session: TabSession

    func makeNSView(context: Context) -> TerminalDropContainer {
        let container = TerminalDropContainer()
        container.session = session
        container.attach(session.terminalView)
        return container
    }

    func updateNSView(_ nsView: TerminalDropContainer, context: Context) {
        nsView.session = session
        // The terminal view is session-owned and moves between hosts on
        // pane/tab rearrangement — reclaim it if another container has it.
        nsView.attach(session.terminalView)
        session.resyncTerminalViewIfNeeded()
    }
}

/// Container for the terminal view that maintains a window-level file-
/// drop overlay for its region.
///
/// Why an overlay instead of a drop handler here: SwiftUI's platform-
/// view host blocks drag-destination routing into its subtree — both
/// `registerForDraggedTypes` on views inside it and `.dropDestination`
/// on the representable go silent (verified empirically: a pure-SwiftUI
/// sibling region targeted fine while this whole subtree never did).
/// The only reliable drop target is a view OUTSIDE that subtree, so the
/// container keeps a transparent, click-through sibling of the window's
/// hosting view frame-synced over itself.
final class TerminalDropContainer: NSView {
    weak var session: TabSession?
    private var overlay: TerminalDropOverlay?

    func attach(_ view: NSView) {
        guard view.superview !== self else { return }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

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

    /// Create/position the overlay while this terminal is visible in a
    /// window; tear it down when hidden (keepAllAlive keeps offstage
    /// tabs mounted — a stale overlay would misroute drops meant for
    /// the tab actually on screen) or unparented (tab closed/moved).
    private func syncOverlay() {
        guard let window, let host = window.contentView,
              !isHiddenOrHasHiddenAncestor else {
            overlay?.removeFromSuperview()
            overlay = nil
            return
        }
        let target = overlay ?? {
            let fresh = TerminalDropOverlay()
            fresh.container = self
            overlay = fresh
            return fresh
        }()
        if target.superview !== host {
            host.addSubview(target, positioned: .above, relativeTo: nil)
        }
        target.frame = convert(bounds, to: host)
    }
}

/// Transparent, click-through drop target parented at window level —
/// outside the SwiftUI platform-view subtree that swallows drag
/// routing. `hitTest` returns nil so every mouse event passes through
/// to the terminal beneath; drag-destination discovery goes by
/// registered types, which is exactly the one signal we want to catch.
///
/// Dropping files types their shell-escaped paths into the OWNING
/// terminal (the drop target is frame-locked to one tab — no "active
/// tab" guessing). One joined send keeps multi-file drops in
/// pasteboard order; trailing space per path matches Terminal.app. No
/// newline — even a claude tab just gets composer text, never a
/// submitted prompt.
final class TerminalDropOverlay: NSView {
    weak var container: TerminalDropContainer?

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
        let text = urls
            .map { FileTreeOperations.shellEscaped($0.path) + " " }
            .joined()
        container?.session?.send(text)
        return true
    }

    private func canReadFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
    }
}
