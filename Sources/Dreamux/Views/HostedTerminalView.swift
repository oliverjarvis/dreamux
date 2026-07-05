import SwiftUI
import GhosttyTerminal
import UniformTypeIdentifiers

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
            // Dropping files types their shell-escaped paths into THIS
            // terminal (the drop target picks the tab — no "active tab"
            // guessing). Trailing space per path matches Terminal.app.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        let text = FileTreeOperations.shellEscaped(url.path) + " "
                        Task { @MainActor in
                            session.send(text)
                        }
                    }
                }
                return !providers.isEmpty
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
