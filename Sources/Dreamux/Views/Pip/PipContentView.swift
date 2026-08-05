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
            // `GeometryReader` rather than the `frame()` closure: this has
            // to re-measure as the user resizes the panel, and a closure
            // is not something SwiftUI can observe.
            GeometryReader { geometry in
                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .environment(\.pipDesktopZoom, desktopZoom(forWidth: geometry.size.width))
            }
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

    /// Browser tabs render their full desktop layout, shrunk to fit — a
    /// pipped site should look like the site, not like the narrow layout
    /// a genuinely 420pt-wide browser would trigger.
    ///
    /// Deliberately browser-only. A pipped editor, diff or Overview wants
    /// readable text at its real size, not a 22% thumbnail, and an applet
    /// is authored for the panel it is drawn in rather than for 1920.
    private func desktopZoom(forWidth width: CGFloat) -> CGFloat? {
        guard isBrowserTab else { return nil }
        return PipContentScale.zoom(forPanelWidth: width)
    }

    private var isBrowserTab: Bool {
        guard case .tab(let workspaceID, let tabID) = target,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID })
        else { return false }
        return store.session(for: workspace).webTabSession(for: tabID) != nil
    }

    @ViewBuilder
    private var content: some View {
        switch target {
        case .tab(let workspaceID, let tabID):
            if let workspace = store.workspaces.first(where: { $0.id == workspaceID }) {
                TabContentView(
                    session: store.session(for: workspace), tabId: tabID, overview: overview)
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
