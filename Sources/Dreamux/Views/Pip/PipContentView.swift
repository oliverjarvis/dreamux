import SwiftUI
import Bonsplit

/// What lives inside a pip: the target's real content with the chrome
/// bar over it. The content branches render exactly what the main window
/// renders — `TabContentView` for a tab, `AppletHostView` for an applet —
/// so the live NSView simply re-parents into this panel.
struct PipContentView: View {
    let target: PipTarget
    let store: WorkspaceStore
    let projectSession: ProjectSession
    let overview: WorkspaceOverviewDependencies
    let pips: PipController
    /// Supplied by `ContentView`, which owns `sidebarMode` — reveal has
    /// to change what the window is showing, which only it can do.
    let onReveal: () -> Void
    let frame: () -> CGRect
    let onDragTo: (CGPoint) -> Void
    let onTidy: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            content
            PipChromeView(
                title: title,
                onBringBack: { pips.close(target) },
                onBringAllBack: { pips.closeAll() },
                onTidy: onTidy,
                onReveal: onReveal,
                frame: frame,
                onDragTo: onDragTo
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch target {
        case .tab(let workspaceID, let tabID):
            if let workspace = store.workspaces.first(where: { $0.id == workspaceID }) {
                let session = store.session(for: workspace)
                // A browser tab is the one kind that does NOT render
                // `TabContentView` in a pip. It streams: the page's own
                // desktop render, shrunk, with the address bar and
                // back/forward left behind — those are what made a pip
                // read as "a small browser" rather than a view of the
                // site. Every other kind wants readable text at true
                // size, so it renders exactly what the pane renders.
                if let webTab = session.webTabSession(for: tabID) {
                    PipScaledWebView(webView: webTab.webView)
                } else {
                    TabContentView(session: session, tabId: tabID, overview: overview)
                }
            } else {
                missingState
            }
        case .applet(let id):
            if let applet = projectSession.applets.applet(id: id) {
                AppletHostView(session: projectSession.appletSession(for: applet))
                    .id(id)
            } else {
                missingState
            }
        }
    }

    /// The target went away underneath the panel. `PipHost` closes such a
    /// pip on its next pass; this is what shows for the frame in between.
    private var missingState: some View {
        VStack(spacing: 8) {
            Image(systemName: "pip.exit")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("This content is no longer open")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch target {
        case .tab(let workspaceID, let tabID):
            guard let workspace = store.workspaces.first(where: { $0.id == workspaceID })
            else { return "Tab" }
            return store.session(for: workspace).controller.tab(tabID)?.title ?? "Tab"
        case .applet(let id):
            return projectSession.applets.applet(id: id)?.manifest.name ?? "Applet"
        }
    }
}
