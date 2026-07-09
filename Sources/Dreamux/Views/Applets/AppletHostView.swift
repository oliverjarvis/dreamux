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
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text("Adopted from App Studio")
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

/// Parents the applet's session-owned preview `WKWebView` — the 4-line
/// representable shape `WebTabView`/`FileEditorView` use, so the same
/// long-lived web view survives every host redraw.
private struct AppletWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
