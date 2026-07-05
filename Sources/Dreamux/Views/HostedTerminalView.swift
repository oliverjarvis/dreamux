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

/// AppKit drop shim around the terminal. SwiftUI's `.onDrop` on the
/// representable proved unreliable with an embedded platform view in
/// the drag-routing path (drops never reached the handler), so the
/// container registers as the drag destination itself — deterministic
/// AppKit, nothing deeper registers to preempt it.
///
/// Dropping files types their shell-escaped paths into THIS terminal
/// (the drop target picks the tab — no "active tab" guessing). One
/// joined send keeps multi-file drops in pasteboard order; trailing
/// space per path matches Terminal.app. No newline — even a claude
/// tab just gets composer text, never a submitted prompt.
final class TerminalDropContainer: NSView {
    weak var session: TabSession?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func attach(_ view: NSView) {
        guard view.superview !== self else { return }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

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
        session?.send(text)
        return true
    }

    private func canReadFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
    }
}
