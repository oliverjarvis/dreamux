import SwiftUI

/// Sheet for binding one applet-declared connection `slot` to a
/// `Connection` — presented by `AppletHostView` whenever
/// `session.pendingBindSlot` is set (the host view's own "Connect" button,
/// or the bridge's `connections.request`, via `AppletSession.requestBind`).
///
/// Pick an existing connection from `store`, or create one inline (embeds
/// `AddConnectionSheet`, reusing its paste/import-from-CLI flow). Either
/// path reports the resulting connection id back through `onBind`, which
/// the caller uses to perform the actual write (`AppletSession.bind`) and
/// then dismiss. `onCancel` dismisses without binding.
///
/// This view never touches `pendingBindSlot`/`completeBind()` itself —
/// `AppletHostView` owns that lifecycle so `completeBind()` fires exactly
/// once per presentation regardless of which affordance closes the sheet.
struct ConnectionBindSheet: View {
    let slot: ConnectionSlot
    @Bindable var store: ConnectionStore
    let onBind: (String) -> Void
    let onCancel: () -> Void

    @State private var showingAddSheet = false
    /// Snapshot of connection ids taken right before presenting
    /// `AddConnectionSheet`, so its shared `onDone: () -> Void` (fired on
    /// both Cancel and Save — it carries no created-connection payload) can
    /// be turned into "was one created?" by diffing `store.connections`
    /// against this set.
    @State private var idsBeforeCreate: Set<String> = []
    @State private var hoveredConnectionID: String?
    @State private var createRowHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect \(slot.label)")
                .font(.title3.weight(.semibold))

            Text(slotDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                if store.connections.isEmpty {
                    Text("No connections yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                } else {
                    ForEach(store.connections) { connection in
                        connectionRow(connection)
                    }
                }
                createNewRow
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .sheet(isPresented: $showingAddSheet) {
            AddConnectionSheet(store: store, prefillSlot: slot, suggestedProvider: slot.suggests, onDone: {
                showingAddSheet = false
                if let created = store.connections.first(where: { !idsBeforeCreate.contains($0.id) }) {
                    onBind(created.id)
                }
            })
        }
    }

    private var slotDescription: String {
        slot.hosts.isEmpty
            ? "This applet needs a connection for \u{201C}\(slot.id)\u{201D}."
            : "This applet needs a connection for \u{201C}\(slot.id)\u{201D} — calls \(slot.hosts.joined(separator: ", "))."
    }

    // MARK: - Rows

    private func connectionRow(_ connection: Connection) -> some View {
        let uncovered = uncoveredHosts(for: connection)
        return Button {
            onBind(connection.id)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "key.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !uncovered.isEmpty {
                        Text("May not cover \(uncovered.joined(separator: ", "))")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
            if hoveredConnectionID == connection.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .onHover { hovering in
            hoveredConnectionID = hovering ? connection.id : (hoveredConnectionID == connection.id ? nil : hoveredConnectionID)
        }
    }

    /// Slot hosts this `connection` doesn't cover — advisory only, still
    /// selectable (the resolver enforces the allowlist at call time; this
    /// is just a heads-up in the picker). Case-insensitive since hosts are
    /// lowercased at use.
    private func uncoveredHosts(for connection: Connection) -> [String] {
        slot.hosts.filter { host in
            !connection.hosts.contains { $0.caseInsensitiveCompare(host) == .orderedSame }
        }
    }

    /// Borderless "+ Create new connection" foot row — same shape as
    /// `ConnectionsSettingsView.addRow`.
    private var createNewRow: some View {
        Button {
            idsBeforeCreate = Set(store.connections.map(\.id))
            showingAddSheet = true
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
                Text("Create new connection")
                    .font(.system(size: 14))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if createRowHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .onHover { createRowHovered = $0 }
    }
}
