import SwiftUI
import Bonsplit
import GhosttyTerminal

/// Holds every workspace's tab/split layout in a single ZStack so each
/// workspace's BonsplitController, NSViews, and PTYs stay alive when the
/// user clicks away. Only the active workspace is visible and accepts input.
struct WorkspaceTerminalContainer: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        ZStack {
            ForEach(store.workspaces) { workspace in
                WorkspaceBonsplitPane(session: store.session(for: workspace))
                    .opacity(workspace.id == store.activeID ? 1 : 0)
                    .allowsHitTesting(workspace.id == store.activeID)
            }
        }
    }
}

private struct WorkspaceBonsplitPane: View {
    @Bindable var session: WorkspaceSession

    var body: some View {
        BonsplitView(controller: session.controller) { tab, paneId in
            TabContentView(session: session, tabId: tab.id, paneId: paneId)
        } emptyPane: { paneId in
            EmptyPaneView {
                session.controller.createTab(
                    title: "shell",
                    icon: "terminal.fill",
                    inPane: paneId
                )
            }
        }
    }
}

private struct TabContentView: View {
    let session: WorkspaceSession
    let tabId: TabID
    let paneId: PaneID

    var body: some View {
        if let tabSession = session.tabSession(for: tabId) {
            TerminalSurfaceView(context: tabSession.viewState)
                .onAppear { tabSession.startIfNeeded() }
        } else {
            Color.clear
        }
    }
}

private struct EmptyPaneView: View {
    let onNewTab: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Button(action: onNewTab) {
                Label("New Shell", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("t", modifiers: [.command])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
