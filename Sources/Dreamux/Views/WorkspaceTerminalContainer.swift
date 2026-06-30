import SwiftUI
import Bonsplit
import GhosttyTerminal
import WebKit

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
                    // Force the active workspace to the top of the ZStack
                    // regardless of declaration order so its drop targets
                    // and gesture recognizers always win — without this,
                    // drag-drop sometimes routes to whichever workspace
                    // was rendered latest in the hierarchy.
                    .zIndex(workspace.id == store.activeID ? 1 : 0)
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
        .onAppear { session.bootstrapIfNeeded() }
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
        } else if let webTab = session.webTabSession(for: tabId) {
            WebTabView(session: webTab)
        } else {
            Color.clear
        }
    }
}

/// An in-app browser tab: slim chrome (URL, reload, escape hatch to the
/// external browser) over a WKWebView. Hosts the `open` target of a
/// running worktree so the app-under-development lives next to the
/// terminals working on it.
private struct WebTabView: View {
    let session: WebTabSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(session.url.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    session.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reload")
                Button {
                    session.openExternally()
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open in external browser")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            WebViewRepresentable(webView: session.webView)
        }
    }
}

private struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
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
