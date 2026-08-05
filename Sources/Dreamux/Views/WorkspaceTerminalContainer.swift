import AppKit
import SwiftUI
import Bonsplit

/// Holds every workspace's tab/split layout in a single ZStack so
/// switching workspaces is an opacity flip, not a view rebuild. The
/// terminal NSViews themselves are session-owned (`TabSession
/// .terminalView`) and would survive teardown anyway; keeping them
/// mounted avoids reparent churn and keeps split layouts warm. Only the
/// active workspace is visible and accepts input.
struct WorkspaceTerminalContainer: View {
    @Bindable var store: WorkspaceStore
    /// This window's open pips, so a pane whose tab is out in a panel can
    /// render the placeholder instead of the content.
    let pips: PipController
    /// The Overview's Mode A dependencies (Group 2) — threaded down to
    /// whichever workspace's Overview tab renders. See
    /// `WorkspaceOverviewView` for what each closure/store does.
    let overview: WorkspaceOverviewDependencies

    var body: some View {
        ZStack {
            if store.workspaces.isEmpty {
                noWorkspacesState
            }
            ForEach(store.workspaces) { workspace in
                WorkspaceBonsplitPane(
                    session: store.session(for: workspace), pips: pips, overview: overview)
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
        // Always claim the full pane. With zero workspaces the ZStack is
        // otherwise empty and reports ~zero ideal height, and no other
        // HSplitView child forces height — the whole split collapses and
        // the hero band floats centered in an empty window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown when the project has no work items at all (fresh project,
    /// or the last feature was just closed).
    private var noWorkspacesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No work items open")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Run a plan from Plans & Specs, or add an ad-hoc work item from the sidebar.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkspaceBonsplitPane: View {
    @Bindable var session: WorkspaceSession
    let pips: PipController
    let overview: WorkspaceOverviewDependencies

    var body: some View {
        BonsplitView(controller: session.controller) { tab, paneId in
            // The pipped check lives HERE, not inside `TabContentView`: a
            // pip renders that same view, so a self-check there would make
            // a pip render its own placeholder forever.
            let target = PipTarget.tab(workspaceID: session.workspace.id, tabID: tab.id)
            if pips.isPipped(target) {
                PipPlaceholderView { pips.close(target) }
            } else {
                TabContentView(session: session, tabId: tab.id, overview: overview)
            }
        } emptyPane: { paneId in
            EmptyPaneView {
                session.controller.createTab(
                    title: "shell",
                    icon: "terminal.fill",
                    inPane: paneId
                )
            }
        } tabBarAccessory: { paneId in
            NewTabControl { kind in
                // Focus this pane first: every `open…` below creates through
                // `BonsplitController.createTab`, which defaults to the
                // FOCUSED pane. Focusing makes the click land in the bar the
                // user clicked, without teaching each open method about panes.
                session.controller.focusPane(paneId)
                openNewTab(kind)
            }
        }
        .onAppear { session.bootstrapIfNeeded() }
    }

    /// The `＋ ⌄` menu's three destinations. "File…" routes through the same
    /// `openFileTab` the file tree and drag-drop use, so a file opened from
    /// the tab bar dedups against an already-open editor tab like any other.
    private func openNewTab(_ kind: NewTabControl.Kind) {
        switch kind {
        case .terminal:
            session.createTab()
        case .browser:
            session.openBlankWebTab()
        case .file:
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Open"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            session.openFileTab(at: url)
        }
    }
}

/// Segmented mode switch shown in a slim bar above multi-mode viewers
/// (markdown Rendered|Raw, tabular Table|Text).
struct ViewerModeToggle: View {
    @Bindable var session: FileEditorTabSession
    /// (label, mode) pairs, in display order.
    let options: [(String, FileTabViewMode)]

    var body: some View {
        HStack {
            Picker("", selection: $session.viewMode) {
                ForEach(options, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if session.isDirty {
                Text("Unsaved changes — ⌘S in Raw to save")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .onChange(of: session.viewMode) { _, newMode in
            // Entering a read view: sync the live Monaco buffer so the
            // render reflects unsaved edits (spec: re-render from the
            // current buffer, not disk).
            if newMode != .source { session.refreshCurrentTextFromEditor() }
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
