import SwiftUI

/// Settings-panel control for `Connection`s (paste-a-token or CLI-imported
/// credentials applets use to call authenticated APIs). House style: 15pt
/// row labels, secondary metadata, the sidebar's hover wash
/// (`Color.primary.opacity(0.04)`/`0.08` on `RoundedRectangle(cornerRadius: 8)`),
/// and a borderless "+ Add connection" foot row.
struct ConnectionsSettingsView: View {
    @Bindable var store: ConnectionStore

    @State private var showingAddSheet = false
    @State private var addRowHovered = false
    @State private var hoveredID: String?
    /// The connection a Delete was fired against, driving the destructive
    /// confirm dialog (the view owns it, not the row).
    @State private var pendingDelete: Connection?
    /// A delete that threw (secret-remove or metadata-save failure) — shown
    /// as a red caption rather than swallowed, so a stuck row isn't silent.
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.connections.isEmpty {
                Text("No connections yet. Add one to let applets call authenticated APIs.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            } else {
                ForEach(store.connections) { connection in
                    connectionRow(connection)
                }
            }
            addRow
            if let deleteError {
                Text(deleteError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddConnectionSheet(store: store, onDone: { showingAddSheet = false })
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.label ?? "connection")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { connection in
            Button("Delete", role: .destructive) {
                do {
                    try store.delete(id: connection.id)
                    deleteError = nil
                } catch {
                    deleteError = "Couldn't delete \"\(connection.label)\": \(error.localizedDescription)"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Removes the stored credential.")
        }
    }

    // MARK: - Row

    private func connectionRow(_ connection: Connection) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "key.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    provenanceChip(connection.source)
                }
                Text("\(kindSummary(connection.kind)) · \(hostsSummary(connection.hosts))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Button {
                pendingDelete = connection
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete connection")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background {
            if hoveredID == connection.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .padding(.horizontal, 4)
            }
        }
        .onHover { hovering in
            hoveredID = hovering ? connection.id : (hoveredID == connection.id ? nil : hoveredID)
        }
        .contextMenu {
            Button("Delete…", role: .destructive) { pendingDelete = connection }
        }
    }

    /// Small static pill: imported-from-CLI (tool name) vs manual vs OAuth
    /// (reserved). Informational, not tappable — matches the app's
    /// static-Capsule chip shape (`FlowLaneView.nodeChip`).
    private func provenanceChip(_ source: Connection.Source) -> some View {
        let (text, tinted): (String, Bool) = {
            switch source {
            case .manual: return ("Manual", false)
            case .importedFromCLI(let tool): return ("Imported · \(tool)", true)
            case .oauth: return ("OAuth", true)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill((tinted ? Color.accentColor : Color.primary).opacity(tinted ? 0.12 : 0.07)))
            .foregroundStyle(tinted ? Color.accentColor : Color.secondary)
    }

    /// Short human summary of an AuthKind, e.g. "Bearer header", "Basic",
    /// "API key", "Env: GH_TOKEN".
    private func kindSummary(_ kind: AuthKind) -> String {
        switch kind {
        case .header(let headerName, let valueTemplate):
            if headerName == "Authorization", valueTemplate.contains("Bearer") {
                return "Bearer header"
            }
            return "API key"
        case .basic:
            return "Basic"
        case .query:
            return "Query param"
        case .env(let vars):
            return "Env: \(vars.joined(separator: ", "))"
        }
    }

    private func hostsSummary(_ hosts: [String]) -> String {
        hosts.isEmpty ? "no hosts" : hosts.joined(separator: ", ")
    }

    /// Borderless "+ Add connection" foot row — the `newAppRow`/
    /// `addRepositoryRow`/`newWorkspaceRow` shape: a plain plus (no circle,
    /// no box), highlighting only on hover.
    private var addRow: some View {
        Button {
            showingAddSheet = true
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
                Text("Add connection")
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
            if addRowHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .padding(.horizontal, 4)
            }
        }
        .onHover { addRowHovered = $0 }
    }
}
