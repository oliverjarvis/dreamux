import AppKit
import Foundation
import Observation
import WebKit

/// State behind one in-app browser tab. Runners' `open` URLs land here
/// (instead of bouncing the user out to an external browser) so each
/// worktree's running app lives as a tab inside its own workspace,
/// right next to the terminals working on it. The header (see
/// `WebTabView`) is a working browser bar driven by this session.
@MainActor
@Observable
final class WebTabSession: Identifiable {
    let id = UUID()
    /// URL this tab was opened for. Also the dedup key: pressing play
    /// again re-selects the existing tab rather than stacking a new one.
    let url: URL

    /// True when this tab was opened with no destination (⌘⇧B / the tab
    /// bar's ＋ ▸ Browser). Its `url` is `about:blank`, the web view skips
    /// its initial load, and `WebTabView` focuses the address bar instead.
    /// Also what exempts the tab from `WorkspaceSession.openWebTab`'s URL
    /// dedup — every blank tab is its own tab.
    let isBlank: Bool

    /// The live location, kept in sync with the web view as the user
    /// navigates. Drives the address bar.
    var currentURL: URL
    var canGoBack = false
    var canGoForward = false

    @ObservationIgnored private var _webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    var webView: WKWebView {
        if let _webView { return _webView }
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Safari's Web Inspector (Develop menu) — a dev tool pointed at
        // the user's own dev server; inspectability is the point.
        view.isInspectable = true
        observeNavigation(view)
        // A blank tab loads nothing: the user is about to type an address.
        if !isBlank {
            view.load(URLRequest(url: url))
        }
        _webView = view
        return view
    }

    init(url: URL) {
        self.url = url
        self.currentURL = url
        self.isBlank = false
    }

    /// A blank tab — no destination, no initial load, address bar focused.
    init() {
        let blank = URL(string: "about:blank")!
        self.url = blank
        self.currentURL = blank
        self.isBlank = true
    }

    func reload() { _webView?.reload() }
    func goBack() { _webView?.goBack() }
    func goForward() { _webView?.goForward() }

    /// Navigate to a typed address: a real URL, a bare host, or (as a
    /// fallback) a Google search — Chrome/Arc omnibox behavior.
    func navigate(to input: String) {
        guard let target = Self.resolveNavigation(input) else { return }
        webView.load(URLRequest(url: target))
    }

    /// Escape hatch to a real browser — the current page, external
    /// default handler.
    func openExternally() {
        NSWorkspace.shared.open(currentURL)
    }

    /// A typed address that resolves to a REAL destination — a scheme'd
    /// URL or a bare host — or nil. Deliberately no search fallback: the
    /// ⌘K palette needs to tell "this is a URL" from "this is prose", and
    /// typing prose into the palette must not offer to google it.
    nonisolated static func directURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme,
           scheme == "http" || scheme == "https" {
            return url
        }
        if !trimmed.contains(" "), trimmed.contains("."),
           let url = URL(string: "https://\(trimmed)") {
            return url
        }
        return nil
    }

    /// The address bar's parser: `directURL`, else a Google search —
    /// Chrome/Arc omnibox behavior. Behaviour is unchanged from before
    /// the `directURL` split.
    nonisolated static func resolveNavigation(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = directURL(trimmed) { return direct }
        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return comps.url
    }

    // MARK: - Navigation observation

    private func observeNavigation(_ view: WKWebView) {
        // WKWebView KVO is delivered on the main thread, so hop straight
        // onto the main actor to read its isolated properties and update
        // our observable state with no runloop delay.
        let sync: @Sendable (WKWebView) -> Void = { [weak self] webView in
            MainActor.assumeIsolated {
                self?.apply(
                    url: webView.url,
                    back: webView.canGoBack,
                    forward: webView.canGoForward
                )
            }
        }
        observations = [
            view.observe(\.url, options: [.new]) { webView, _ in sync(webView) },
            view.observe(\.canGoBack, options: [.new]) { webView, _ in sync(webView) },
            view.observe(\.canGoForward, options: [.new]) { webView, _ in sync(webView) },
        ]
    }

    private func apply(url: URL?, back: Bool, forward: Bool) {
        if let url { currentURL = url }
        canGoBack = back
        canGoForward = forward
    }
}
