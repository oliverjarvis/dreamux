import AppKit
import Foundation
import Observation
import WebKit

/// State behind one in-app browser tab. Runners' `open` URLs land here
/// (instead of bouncing the user out to an external browser) so each
/// worktree's running app lives as a tab inside its own workspace,
/// right next to the terminals working on it.
@MainActor
@Observable
final class WebTabSession: Identifiable {
    let id = UUID()
    /// URL this tab was opened for. Also the dedup key: pressing play
    /// again re-selects the existing tab rather than stacking a new
    /// one per run.
    let url: URL

    /// Created lazily so constructing the session (and unit-testing
    /// the open/dedup bookkeeping) doesn't pay for a WebKit process.
    private var _webView: WKWebView?

    var webView: WKWebView {
        if let _webView { return _webView }
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Safari's Web Inspector (Develop menu) — this is a dev tool
        // pointing at the user's own dev server; inspectability is the
        // point.
        view.isInspectable = true
        view.load(URLRequest(url: url))
        _webView = view
        return view
    }

    init(url: URL) {
        self.url = url
    }

    func reload() {
        _webView?.reload()
    }

    /// Escape hatch to a real browser (devtools muscle memory, profile
    /// cookies, extensions) — same URL, external default handler.
    func openExternally() {
        NSWorkspace.shared.open(url)
    }
}
