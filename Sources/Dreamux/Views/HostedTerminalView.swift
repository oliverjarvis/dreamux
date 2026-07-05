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
    /// Whether this tab is the selected tab of its pane. Threaded down
    /// from `TabContentView`, which reads it fresh on every body
    /// evaluation — see `TerminalDropContainer` for why AppKit-level
    /// visibility can't be the gate here.
    var dropTargetEnabled: Bool = true

    var body: some View {
        HostedTerminalRepresentable(session: session, dropTargetEnabled: dropTargetEnabled)
            .background(.clear)
            // Same light/dark adoption `TerminalSurfaceView` performs.
            .onChange(of: colorScheme, initial: true) {
                session.viewState.adopt(colorScheme: colorScheme)
            }
    }
}

private struct HostedTerminalRepresentable: NSViewRepresentable {
    let session: TabSession
    let dropTargetEnabled: Bool

    func makeNSView(context: Context) -> TerminalDropContainer {
        let container = TerminalDropContainer()
        container.session = session
        container.attach(session.terminalView)
        container.dropTargetEnabled = dropTargetEnabled
        return container
    }

    func updateNSView(_ nsView: TerminalDropContainer, context: Context) {
        nsView.session = session
        // The terminal view is session-owned and moves between hosts on
        // pane/tab rearrangement — reclaim it if another container has it.
        nsView.attach(session.terminalView)
        session.resyncTerminalViewIfNeeded()
        nsView.dropTargetEnabled = dropTargetEnabled
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
///
/// The overlay exists only for the pane's SELECTED tab. Dreamux's
/// `WorkspaceSession` uses bonsplit's `contentViewLifecycle:
/// .keepAllAlive`, which keeps every tab's content view mounted in a
/// `ZStack` with `.opacity(selected ? 1 : 0)` (`PaneContainerView
/// .contentArea`) — background tabs never get hidden via `NSView
/// .isHidden`, their frame never changes, and they never leave the
/// window. That means `viewDidHide`/`viewDidUnhide`/`layout()` fire
/// only for pane-level hiding (e.g. a whole split collapsing), never
/// for a same-pane tab switch — so AppKit visibility alone would leave
/// every background tab's overlay live and stacked at the same window
/// rect as the foreground tab, letting a drop route to the wrong shell.
/// `dropTargetEnabled` (driven by `BonsplitController.isTabSelected`,
/// re-read reactively in `TabContentView.body`) is the actual gate;
/// the window/hidden checks below remain because pane-level hiding
/// still uses `isHidden` via `SplitContainerView`, and unparenting
/// still matters when a tab closes or moves.
final class TerminalDropContainer: NSView {
    weak var session: TabSession?
    private var overlay: TerminalDropOverlay?

    /// Whether this tab is the selected tab of its pane. `false` for
    /// every offstage tab kept alive by `.keepAllAlive` — those never
    /// get an overlay, even though they're mounted and full-frame.
    var dropTargetEnabled: Bool = true {
        didSet {
            guard oldValue != dropTargetEnabled else { return }
            syncOverlay()
        }
    }

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

    /// Create/position the overlay while this terminal is the selected
    /// tab and visible in a window; tear it down when deselected,
    /// hidden (keepAllAlive keeps offstage tabs mounted — a stale
    /// overlay would misroute drops meant for the tab actually on
    /// screen), or unparented (tab closed/moved).
    private func syncOverlay() {
        guard dropTargetEnabled, let window, let host = window.contentView,
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
