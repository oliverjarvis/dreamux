import SwiftUI

/// The APPLETS sidebar section — Applet Studio applets adopted or created
/// inside this project. House style: a 13pt uppercase header with a chevron
/// collapse (persisted via `layout.appsExpanded`), 15pt applet rows, a
/// "+ New applet" foot row, and a visible (non-clickable) warning row per
/// invalid folder so a broken applet degrades in plain sight rather than
/// vanishing.
struct AppsSection: View {
    @Bindable var applets: ProjectAppletStore
    @Bindable var layout: SidebarLayoutStore
    @Binding var sidebarMode: SidebarMode
    let onOpenApplet: (Applet) -> Void      // sets sidebarMode = .app(id)
    let onNewApp: () -> Void                // opens NewAppSheet
    let onRemove: (Applet) -> Void          // confirm + store.remove (+ closeAppletSession)
    let onPublish: (Applet) -> Void         // local-born only

    @State private var hoveredAppletID: UUID?
    @State private var newAppHovered = false
    /// The applet a *Remove from project…* was fired against, driving the
    /// destructive confirm dialog (the section owns it, not the row).
    @State private var pendingRemove: Applet?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if layout.appsExpanded {
                ForEach(applets.applets) { applet in
                    appletRow(applet)
                }
                ForEach(applets.invalidFolders, id: \.self) { name in
                    invalidRow(name)
                }
                newAppRow
            }
        }
        // The apps/ folder is the source of truth; a full watcher is deferred,
        // so re-scan whenever the section (re)appears.
        .onAppear { applets.refresh() }
        .confirmationDialog(
            "Remove \(pendingRemove?.manifest.name ?? "applet")?",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            presenting: pendingRemove
        ) { applet in
            Button("Delete", role: .destructive) { onRemove(applet) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Deletes the applet folder and its data. This can't be undone.")
        }
    }

    // MARK: - Pieces

    /// Chevron + "APPLETS" — identical construction to
    /// `PlansSpecsSection.header`, toggling the persisted `layout.appsExpanded`.
    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { layout.appsExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(layout.appsExpanded ? 90 : 0))
                Text("Applets")
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    /// One openable applet row — its manifest icon in a fixed 28pt column, a
    /// 15pt name, and (for an adopted copy) a trailing `square.on.square`
    /// provenance glyph. Selected while its host is on screen.
    private func appletRow(_ applet: Applet) -> some View {
        let selected = sidebarMode == .app(applet.id)
        return Button {
            onOpenApplet(applet)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: applet.manifest.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .frame(width: 28)
                Text(applet.manifest.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if applet.isAdopted {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .help("Adopted from Applet Studio")
                }
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

    /// A folder under apps/ whose manifest failed to load — shown, not hidden,
    /// so the user can see and fix it (spec: degrade visibly, never crash).
    private func invalidRow(_ name: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
                .frame(width: 28)
            Text(name)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .help("apps/\(name)/manifest.json is missing or invalid")
    }

    /// Borderless "＋ New applet" foot row — the `newWorkspaceRow` shape: a
    /// plain plus (no circle, no box), highlighting only on hover.
    private var newAppRow: some View {
        Button(action: onNewApp) {
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
        Button("Remove from project…") { pendingRemove = applet }
        // Publishing an *adopted* copy back would fork its origin — only a
        // local-born applet (no origin) can seed the library.
        if applet.manifest.origin == nil {
            Button("Publish to Applet Studio") { onPublish(applet) }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([applet.folderURL])
        }
    }
}
