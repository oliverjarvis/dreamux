import SwiftUI
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

    func makeNSView(context: Context) -> TerminalView { session.terminalView }
    func updateNSView(_ nsView: TerminalView, context: Context) {
        session.resyncTerminalViewIfNeeded()
    }
}
