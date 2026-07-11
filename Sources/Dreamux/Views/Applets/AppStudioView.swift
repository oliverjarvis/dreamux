import SwiftUI

/// The global Applet Studio window (`Window("Applet Studio", id: "app-studio")`
/// in `DreamuxApp`) — the canonical applet library, reachable from the
/// projects rail rather than any one project. A left column lists every
/// applet under `AppLibraryStore.root` (create/select/delete, house style
/// borrowed from `AppsSection`); the right column hosts the selection with
/// the same `AppletHostView` a project uses.
///
/// Editing here edits the CANON directly — same host view, same library
/// folder, its own scratch data (`AppStudioData/<slug>` under Application
/// Support) since there is no project to hold `.dreamux/appdata/`. The
/// builder agent's cwd is the library applet's own folder.
struct AppStudioView: View {
    @State private var library = AppLibraryStore()
    @State private var sessions: [UUID: AppletSession] = [:]
    @State private var selectedID: UUID?

    @State private var showNewApp = false
    @State private var pendingDelete: Applet?
    @State private var actionError: String?
    @State private var hoveredAppletID: UUID?
    @State private var newAppHovered = false

    var body: some View {
        HSplitView {
            libraryColumn
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 360)
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { library.refresh() }
        .sheet(isPresented: $showNewApp) {
            NewAppSheet(
                library: [],
                onCreate: { name, description in
                    showNewApp = false
                    handleCreate(name: name, description: description)
                },
                onAdopt: nil,
                onCancel: { showNewApp = false }
            )
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.manifest.name ?? "applet")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { applet in
            Button("Delete", role: .destructive) { handleDelete(applet) }
            Button("Cancel", role: .cancel) {}
        } message: { applet in
            // `library.delete` trashes the folder (fm.trashItem), so unlike
            // AppsSection's hard remove, this IS recoverable — say so.
            Text("Moves “\(applet.manifest.name)” to the Trash. You can restore it from Finder.")
        }
        .alert(
            "Couldn't complete action",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            presenting: actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    // MARK: - Left column

    private var libraryColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(library.applets) { applet in
                        appletRow(applet)
                    }
                    newAppRow
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// "APPLET STUDIO" — 13pt semibold uppercase, kern 0.4, house style —
    /// plus a Refresh `.soft` button. The one deliberate header-icon
    /// exception: this is a standalone window (no toolbar), not the project
    /// sidebar where add-actions live as foot rows only.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Applet Studio")
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.4)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                library.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.soft)
            .help("Refresh the Applet Studio library")
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    /// One library applet row: icon (15pt/28pt frame), 15pt name, 13pt
    /// secondary description — mirrors `AppsSection.appletRow`'s wash and
    /// icon column, with a description subtitle since this is the
    /// browse-the-whole-library surface rather than a per-project list.
    private func appletRow(_ applet: Applet) -> some View {
        let selected = selectedID == applet.id
        return Button {
            selectApplet(applet)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: applet.manifest.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(applet.manifest.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    if !applet.manifest.description.isEmpty {
                        Text(applet.manifest.description)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if selected || hoveredAppletID == applet.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.08 : 0.04))
                    .padding(.horizontal, 4)
            }
        }
        .onHover { hovering in
            if hovering { hoveredAppletID = applet.id }
            else if hoveredAppletID == applet.id { hoveredAppletID = nil }
        }
        .contextMenu { appletMenu(applet) }
    }

    /// Borderless "＋ New app" foot row — the same plain-plus shape as
    /// `AppsSection.newAppRow` / the sidebar's other add-actions.
    private var newAppRow: some View {
        Button {
            showNewApp = true
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
                Text("New applet")
                    .font(.system(size: 15))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if newAppHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .padding(.horizontal, 4)
            }
        }
        .onHover { newAppHovered = $0 }
    }

    @ViewBuilder
    private func appletMenu(_ applet: Applet) -> some View {
        Button("Delete…") { pendingDelete = applet }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([applet.folderURL])
        }
    }

    // MARK: - Right column

    @ViewBuilder
    private var detail: some View {
        if let selectedID, let applet = library.applet(id: selectedID) {
            AppletHostView(session: session(for: applet))
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Canonical applets live here; projects adopt copies.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    /// Create-on-select: pick the row and make sure its session exists
    /// before the detail pane renders it.
    private func selectApplet(_ applet: Applet) {
        selectedID = applet.id
        _ = session(for: applet)
    }

    /// The live session behind a library applet, cached by id — its
    /// `WKWebView` and builder-agent terminal must outlive `AppStudioView`'s
    /// redraws. Scratch data (spec point 3): there's no project here, so it
    /// gets its own `AppStudioData/<slug>` under the same
    /// `DREAMUX_STATE_DIR`-aware Application Support root `ProjectStore`
    /// resolves to; cwd is the applet's own folder (`projectRoot`).
    private func session(for applet: Applet) -> AppletSession {
        if let existing = sessions[applet.id] { return existing }
        let dataDir = ProjectStore.stateRootURL()
            .appendingPathComponent("AppStudioData", isDirectory: true)
            .appendingPathComponent(applet.slug, isDirectory: true)
        let session = AppletSession(applet: applet, dataDir: dataDir, projectRoot: applet.folderURL)
        sessions[applet.id] = session
        return session
    }

    /// CREATE: scaffold a canonical applet, spawn its builder agent with the
    /// description-seeded kickoff, and select it — mirrors
    /// `WorkspaceSidebar.handleCreateApp`'s create-only path.
    private func handleCreate(name: String, description: String) {
        do {
            let applet = try library.createApplet(name: name, description: description, icon: "shippingbox")
            session(for: applet).beginEditing(
                kickoff: AppletScaffold.kickoffPrompt(appletName: name, description: description))
            selectedID = applet.id
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Delete: tear down any live session for the deleted applet first (its
    /// hot-reload poller and builder agent, if any) — unconditionally, since
    /// the folder is going away regardless of what's selected — then trash
    /// the folder and clear the selection if it was the one on screen.
    private func handleDelete(_ applet: Applet) {
        sessions[applet.id]?.stopAgent()
        sessions.removeValue(forKey: applet.id)
        do {
            try library.delete(applet)
            if selectedID == applet.id { selectedID = nil }
        } catch {
            actionError = error.localizedDescription
        }
    }
}
