import SwiftUI
import WebKit

/// The main-pane host for an open applet: a slim header bar (icon, name,
/// provenance, a JS-error badge, and Edit/Reload/Reveal actions) above the
/// locked-down preview `WKWebView`. In Edit mode the preview shares an
/// `HSplitView` with the builder-agent terminal so the user can watch the
/// applet hot-reload as the agent works its folder.
struct AppletHostView: View {
    @Bindable var session: AppletSession

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            bindBanner
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: pendingBindSlotItem) { item in
            ConnectionBindSheet(
                slot: declaredSlot(forID: item.id),
                store: .shared,
                onBind: { connectionID in
                    try? session.bind(slot: item.id, toConnectionID: connectionID)
                },
                onCancel: { session.completeBind() }
            )
        }
    }

    /// Subtle, non-modal strip shown under the header whenever this applet
    /// has a declared connection slot with no *working* binding
    /// (`unboundConnectionSlots` is dangling-aware — see its doc comment).
    /// With multiple such slots, the banner names only the first; binding it
    /// clears it from the list and the banner recomputes to name the next,
    /// so slots are handled one at a time rather than the sheet trying to
    /// juggle several at once — simplest clean UX for what should be a rare
    /// multi-slot case.
    @ViewBuilder
    private var bindBanner: some View {
        if let slot = session.unboundConnectionSlots.first {
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                Text("\(slot.label) connection needed")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Connect") {
                    session.pendingBindSlot = slot.id
                }
                .buttonStyle(.soft)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.08))
        }
    }

    /// Wraps `session.pendingBindSlot` (a plain `String?`) into an
    /// `Identifiable` for `.sheet(item:)`, and doubles as the backstop that
    /// guarantees `completeBind()` fires exactly once per presentation: the
    /// sheet's own bind/cancel paths already call it (via
    /// `AppletSession.bind`/`completeBind`, which set `pendingBindSlot` to
    /// nil), and this binding's `set` only fires `completeBind()` for some
    /// OTHER dismissal that skips both — guarded by `pendingBindSlot != nil`
    /// so it can never double-fire once already cleared.
    private var pendingBindSlotItem: Binding<PendingBindSlot?> {
        Binding(
            get: { session.pendingBindSlot.map(PendingBindSlot.init) },
            set: { newValue in
                if newValue == nil, session.pendingBindSlot != nil {
                    session.completeBind()
                }
            }
        )
    }

    /// The manifest's own metadata for a pending slot id (label/hosts for
    /// the sheet's copy and host-coverage check). Falls back to a bare slot
    /// so a stale id (manifest edited out from under an in-flight bind)
    /// can't crash the sheet — it just shows less detail.
    private func declaredSlot(forID id: String) -> ConnectionSlot {
        session.applet.manifest.requiresConnections.first { $0.id == id }
            ?? ConnectionSlot(id: id, label: id, hosts: [], suggests: nil)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: session.applet.manifest.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text(session.applet.manifest.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
            if session.applet.isAdopted {
                Text("Adopted from Applet Studio")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let error = session.lastJSError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .help(error)
            }
            Spacer(minLength: 0)
            Button(session.isEditing ? "Done" : "Edit") {
                if session.isEditing {
                    session.endEditing()
                } else {
                    session.beginEditing(kickoff: nil)
                }
            }
            .buttonStyle(.soft)
            Button("Reload") { session.reload() }
                .buttonStyle(.soft)
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([session.applet.folderURL])
            }
            .buttonStyle(.soft)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        // `isEditing` implies a live `agentTab` (beginEditing creates it);
        // the `if let` is belt-and-braces — a nil tab degrades to the plain
        // preview rather than trapping.
        if session.isEditing, let agentTab = session.agentTab {
            HSplitView {
                preview
                HostedTerminalView(session: agentTab, dropTargetEnabled: false)
                    .onAppear { agentTab.startIfNeeded() }
                    .frame(minWidth: 320)
            }
        } else {
            preview
        }
    }

    private var preview: some View {
        AppletWebViewRepresentable(webView: session.webView)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `.sheet(item:)` needs `Identifiable`; `AppletSession.pendingBindSlot` is
/// a plain slot-id `String?`, so this just wraps it.
private struct PendingBindSlot: Identifiable {
    let id: String
}

/// Parents the applet's session-owned preview `WKWebView` — the 4-line
/// representable shape `WebTabView`/`FileEditorView` use, so the same
/// long-lived web view survives every host redraw.
private struct AppletWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
