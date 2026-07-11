import SwiftUI
import Bonsplit
import GhosttyTerminal
import WebKit

/// Holds every workspace's tab/split layout in a single ZStack so
/// switching workspaces is an opacity flip, not a view rebuild. The
/// terminal NSViews themselves are session-owned (`TabSession
/// .terminalView`) and would survive teardown anyway; keeping them
/// mounted avoids reparent churn and keeps split layouts warm. Only the
/// active workspace is visible and accepts input.
struct WorkspaceTerminalContainer: View {
    @Bindable var store: WorkspaceStore
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
                WorkspaceBonsplitPane(session: store.session(for: workspace), overview: overview)
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
    let overview: WorkspaceOverviewDependencies

    var body: some View {
        BonsplitView(controller: session.controller) { tab, paneId in
            TabContentView(session: session, tabId: tab.id, paneId: paneId, overview: overview)
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
    let overview: WorkspaceOverviewDependencies

    var body: some View {
        if session.isOverviewTab(tabId) {
            WorkspaceOverviewView(
                session: session,
                flows: overview.flows,
                docStore: overview.docStore,
                planQueue: overview.planQueue,
                repoStore: overview.repoStore,
                featureName: overview.featureName,
                featureExists: overview.featureExists,
                onOpenDoc: overview.onOpenDoc,
                onOpenDocAtLine: overview.onOpenDocAtLine,
                makeRunControls: overview.makeRunControls,
                onRunPlan: overview.onRunPlan,
                hasLiveAgent: overview.hasLiveAgent,
                gateActions: overview.gateActions,
                onNewPlan: overview.onNewPlan,
                onOpenRun: overview.onOpenRun,
                onViewTaskChanges: overview.onViewTaskChanges,
                onCourseCorrectionNudge: overview.onCourseCorrectionNudge,
                onOpenRunFlow: overview.onOpenRunFlow
            )
        } else if let tabSession = session.tabSession(for: tabId) {
            // Read inside `body` (not cached in `onAppear`/`onChange`) so
            // this view depends on `PaneState.selectedTabId` -- the same
            // `@Observable` property `TabBarView` reads -- and re-renders
            // on every tab switch. `.keepAllAlive` keeps every tab's
            // content mounted, so this is what gates the terminal's file-
            // drop overlay to the one tab actually on screen; see
            // `TerminalDropContainer`.
            let isSelectedTab = session.controller.isTabSelected(tabId)
            ZStack(alignment: .topTrailing) {
                if tabSession.face == .chat, tabSession.binding.hasEverBound {
                    ChatFaceView(
                        tab: tabSession,
                        onFlipToTerminal: { tabSession.face = .terminal },
                        onOpenTranscript: { session.openFileTab(at: $0) }
                    )
                } else {
                    HostedTerminalView(session: tabSession, dropTargetEnabled: isSelectedTab)
                        .onAppear { tabSession.startIfNeeded() }
                }
                if tabSession.binding.hasEverBound {
                    FaceTogglePill(tab: tabSession)
                        .padding(.top, 8)
                        .padding(.trailing, 12)
                }
            }
            .onChange(of: tabSession.binding.hasEverBound) { _, bound in
                if bound { tabSession.autoFlipToChatOnce() }
            }
        } else if let fileTab = session.fileTabSession(for: tabId) {
            FileEditorView(session: fileTab)
        } else if let diffTab = session.diffTabSession(for: tabId) {
            DiffTabView(session: diffTab)
        } else if let webTab = session.webTabSession(for: tabId) {
            WebTabView(session: webTab)
        } else {
            Color.clear
        }
    }
}

/// The Chat|Terminal face switch overlaid on a bound tab. Two segments
/// sharing one outlined pill (see `HeaderRunControls` for the same
/// shape) split by a hairline divider; the active segment reads
/// `.primary` on a faint fill, the inactive one `.secondary` with a
/// hover wash. Sits on `.ultraThinMaterial` so it stays legible over
/// live terminal content.
private struct FaceTogglePill: View {
    let tab: TabSession

    var body: some View {
        HStack(spacing: 0) {
            segment("Chat", face: .chat)
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1, height: 16)
            segment("Terminal", face: .terminal)
        }
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color.primary.opacity(0.04))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func segment(_ title: String, face: TabSession.TabFace) -> some View {
        FaceSegmentButton(title: title, isActive: tab.face == face) { tab.face = face }
    }
}

/// One segment of `FaceTogglePill` — its own `@State` for the hover wash
/// so hovering one segment never re-renders the other.
private struct FaceSegmentButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.primary.opacity(0.08)
                      : (hovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { hovering = $0 }
    }
}

/// An in-app browser tab: a working browser bar (back/forward, reload,
/// editable address field, escape hatch to the external browser) over a
/// WKWebView. Hosts the `open` target of a running worktree so the
/// app-under-development lives next to the terminals working on it.
private struct WebTabView: View {
    @Bindable var session: WebTabSession
    @State private var address: String = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                navButton("chevron.left", enabled: session.canGoBack) { session.goBack() }
                    .help("Back")
                navButton("chevron.right", enabled: session.canGoForward) { session.goForward() }
                    .help("Forward")
                navButton("arrow.clockwise", enabled: true) { session.reload() }
                    .help("Reload")

                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .focused($addressFocused)
                    .onSubmit {
                        session.navigate(to: address)
                        addressFocused = false
                    }

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
        .onAppear { address = session.currentURL.absoluteString }
        .onChange(of: session.currentURL) { _, newURL in
            // Track the live page, but don't fight the user mid-edit.
            if !addressFocused { address = newURL.absoluteString }
        }
    }

    private func navButton(
        _ symbol: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .secondary : .tertiary)
        .disabled(!enabled)
    }
}

private struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Dispatch a file tab to its kind's viewer. Monaco-backed kinds can
/// still be unsupported (binary/oversized text); media kinds were
/// existence-checked at open.
private struct FileEditorView: View {
    @Bindable var session: FileEditorTabSession

    var body: some View {
        if session.kind == .transcript {
            // The transcript viewer reads the file itself (no Monaco 2 MB
            // gate) and renders its own missing / too-large / empty states,
            // so route to it before the generic supported-file check.
            TranscriptView(fileURL: session.fileURL)
        } else if !session.isSupported || session.useQuickLookFallback {
            if session.useQuickLookFallback {
                QuickLookPreviewView(fileURL: session.fileURL)
            } else {
                UnsupportedFileView(session: session)
            }
        } else {
            switch session.kind {
            case .markdown:
                MarkdownTabView(session: session)
            case .tabular:
                TabularTabView(session: session)
            case .image:
                ImageViewerView(fileURL: session.fileURL)
            case .video, .audio:
                MediaPlayerView(fileURL: session.fileURL)
            case .pdf:
                PDFViewerView(fileURL: session.fileURL)
            case .officePreview:
                QuickLookPreviewView(fileURL: session.fileURL)
            case .transcript:
                TranscriptView(fileURL: session.fileURL)
            case .code:
                FileEditorWebView(webView: session.webView)
            }
        }
    }
}

/// The diff tab: changed-file rail + Monaco side-by-side. Read-only by
/// construction — the session has no save path.
private struct DiffTabView: View {
    @Bindable var session: DiffTabSession

    var body: some View {
        HSplitView {
            List(session.files, selection: Binding(
                get: { session.selectedPath },
                set: { if let path = $0 { session.selectFile(path) } }
            )) { file in
                HStack(spacing: 6) {
                    Text(file.status.prefix(1))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(file.status))
                        .frame(width: 14)
                    Text(file.path)
                        .font(.callout)
                        .lineLimit(1).truncationMode(.head)
                }
                .tag(file.path)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 340)

            FileEditorWebView(webView: session.webView)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if session.isLoading {
                ProgressView()
            } else if session.files.isEmpty {
                Text("No changes in this range")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.first {
        case "A": return .green
        case "D": return .red
        case "R": return .orange
        default: return .secondary
        }
    }
}

/// Placeholder for text files that are binary or over the 2 MB cap,
/// with escape hatches: Quick Look often renders what Monaco can't.
private struct UnsupportedFileView: View {
    @Bindable var session: FileEditorTabSession

    private var fileSizeLabel: String? {
        guard let values = try? session.fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Can't display \(session.title)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(fileSizeLabel.map { "It's binary or too large to edit (\($0), 2 MB cap)." }
                 ?? "It's binary, larger than 2 MB, or missing from disk.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                Button("Try Quick Look") { session.useQuickLookFallback = true }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.fileURL])
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileEditorWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
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

/// A markdown tab: rendered preview by default, Monaco behind a toggle.
/// The webview (and its model/undo stack) is retained by the session,
/// so flipping modes never loses editor state.
private struct MarkdownTabView: View {
    @Bindable var session: FileEditorTabSession

    var body: some View {
        VStack(spacing: 0) {
            ViewerModeToggle(session: session,
                             options: [("Rendered", .rendered), ("Raw", .source)])
            Divider()
            if session.viewMode == .rendered {
                MarkdownPreviewView(text: session.currentText)
            } else {
                FileEditorWebView(webView: session.webView)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A CSV/TSV tab: parsed table by default, Monaco text behind a toggle.
private struct TabularTabView: View {
    @Bindable var session: FileEditorTabSession

    private var delimiter: Character {
        session.fileURL.pathExtension.lowercased() == "tsv" ? "\t" : ","
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewerModeToggle(session: session,
                             options: [("Table", .table), ("Text", .source)])
            Divider()
            if session.viewMode == .table {
                CSVTableView(text: session.currentText, delimiter: delimiter)
            } else {
                FileEditorWebView(webView: session.webView)
            }
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
