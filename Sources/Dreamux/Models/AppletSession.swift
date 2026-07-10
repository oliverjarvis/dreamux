import AppKit
import Foundation
import Observation
import WebKit

/// Everything live behind one open applet: the preview `WKWebView` (lazy,
/// custom scheme + native bridge + nav lockdown), the optional builder-agent
/// terminal, and a folder poller for hot reload. Held per-applet by whatever
/// owns App Studio (`ProjectSession` / `AppStudioView`) — NOT rebuilt per
/// render, the same discipline `FileEditorTabSession`/`WebTabSession` use to
/// keep a `WKWebView` alive across SwiftUI redraws.
@MainActor
@Observable
final class AppletSession: @MainActor Identifiable {
    private(set) var applet: Applet
    let dataStore: AppletDataStore
    let projectRoot: URL
    var id: UUID { applet.id }

    /// Resolves this applet's declared connection slots to live credentials
    /// for `{connection}`-tagged `http.fetch`/`shell.exec`. Built in `init`
    /// from the app-wide `ConnectionStore.shared` and a per-applet
    /// `ConnectionBindingStore` under this applet's own data dir — kept
    /// internal to the session; the bridge reaches it via `owner.connections`.
    let connections: AppletConnectionResolver

    /// Non-nil while a slot needs binding: drives the host-view bind sheet
    /// (T8). `connections.request` sets this and awaits `completeBind()`.
    var pendingBindSlot: String?

    /// Resumed by `completeBind()` once the bind sheet dismisses. Continuation
    /// carried out of `@Observable` tracking — it is control flow, not state.
    @ObservationIgnored private var bindContinuation: CheckedContinuation<Void, Never>?

    /// Header error badge: last `window.onerror`/`unhandledrejection` text
    /// forwarded by the injected error-forwarding script.
    var lastJSError: String?
    var isEditing = false
    private(set) var agentTab: TabSession?

    @ObservationIgnored private var _webView: WKWebView?
    /// Held strongly here — `WKWebView.navigationDelegate` is a weak
    /// reference, so nothing else keeps this alive.
    @ObservationIgnored private var navigationPolicy: AppletNavigationPolicy?
    @ObservationIgnored private var hotReloadTimer: Timer?
    @ObservationIgnored private var lastKnownModificationDate: Date?

    init(applet: Applet, dataDir: URL, projectRoot: URL) {
        self.applet = applet
        let dataStore = AppletDataStore(dataDir: dataDir)
        self.dataStore = dataStore
        self.projectRoot = projectRoot
        self.connections = AppletConnectionResolver(
            store: .shared,
            bindings: ConnectionBindingStore(dataDir: dataStore.dataDir)
        )
    }

    /// Manifest-declared connection slots this applet has no binding for yet
    /// — the T8 bind banner lists these. Reads observable binding state, so
    /// it re-evaluates when a slot is bound/unbound.
    var unboundConnectionSlots: [ConnectionSlot] {
        applet.manifest.requiresConnections.filter {
            connections.bindings.connectionID(forSlot: $0.id) == nil
        }
    }

    /// Open the bind sheet for `slot` and suspend until it dismisses, then
    /// report the resulting binding status back to the caller (the
    /// `connections.request` bridge method). Any in-flight request is resolved
    /// first so a stray second call can't leak its continuation.
    func requestBind(slot: String) async -> AppletConnectionResolver.Status {
        completeBind()
        pendingBindSlot = slot
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            bindContinuation = continuation
        }
        return connections.status(slot: slot)
    }

    /// Called by the bind sheet on dismiss (bound or cancelled): clears the
    /// pending slot and resumes the awaiting `requestBind`, if any.
    func completeBind() {
        pendingBindSlot = nil
        if let continuation = bindContinuation {
            bindContinuation = nil
            continuation.resume()
        }
    }

    /// The live preview surface: a locked-down `WKWebView` serving this
    /// applet's folder over `dreamux-applet://`, wired to the native
    /// `window.dreamux` bridge. Built once, on first access.
    var webView: WKWebView {
        if let _webView { return _webView }

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            AppletSchemeHandler(root: applet.folderURL),
            forURLScheme: AppletSchemeHandler.scheme
        )
        config.userContentController.add(AppletBridge(owner: self), name: "dreamux")

        // Forwards uncaught JS errors/rejections to the native side so the
        // header can surface a badge — the applet's own code never has to
        // opt into this.
        let errorForwardingSource = """
        window.onerror = (m,s,l) => webkit.messageHandlers.dreamux.postMessage({method:'__error', text: m + ' (' + s + ':' + l + ')'});
        window.onunhandledrejection = e => webkit.messageHandlers.dreamux.postMessage({method:'__error', text: String(e.reason)});
        """
        config.userContentController.addUserScript(WKUserScript(
            source: errorForwardingSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let view = WKWebView(frame: .zero, configuration: config)
        let policy = AppletNavigationPolicy()
        navigationPolicy = policy
        view.navigationDelegate = policy
        view.isInspectable = true

        let url = URL(string: "\(AppletSchemeHandler.scheme)://\(applet.id.uuidString)/index.html")!
        view.load(URLRequest(url: url))

        _webView = view
        startHotReloadTimerIfNeeded()
        return view
    }

    /// Re-reads `manifest.json` (capabilities may have changed since the
    /// applet was opened), clears the error badge, and reloads the preview.
    /// Safe to call before the webview has ever been created — it's then
    /// just a manifest refresh with nothing to reload.
    func reload() {
        if let manifest = AppletManifest.load(from: applet.folderURL) {
            applet = Applet(manifest: manifest, folderURL: applet.folderURL)
        }
        lastJSError = nil
        _webView?.reload()
    }

    /// Open (or reveal) the builder agent terminal, cwd'd in the applet's
    /// folder. `kickoff` non-nil types the first prompt (create flow); nil
    /// opens `claude` with a short "read APPLET.md; the user will direct
    /// you" prompt (edit flow, including re-entry after `endEditing`).
    func beginEditing(kickoff: String?) {
        if agentTab == nil {
            let tab = TabSession(cwd: applet.folderURL.path, onActivity: { _ in })
            agentTab = tab
            tab.startIfNeeded()
        }
        ClaudePromptDriver.send(kickoff ?? Self.editPrompt, into: agentTab!)
        isEditing = true
    }

    /// Leave editing mode. The terminal session is kept alive — re-entry
    /// via `beginEditing` is instant, no new `claude` process.
    func endEditing() {
        isEditing = false
    }

    /// Tear down everything live behind this applet — call when it closes.
    func stopAgent() {
        hotReloadTimer?.invalidate()
        hotReloadTimer = nil
        agentTab?.stop()
        agentTab = nil
    }

    private static let editPrompt = "Read APPLET.md in this folder first — it documents the applet format and the window.dreamux bridge. The user will direct you from here; the preview hot-reloads on every save."

    // MARK: - Hot reload

    /// A 1-second poller comparing the folder's max `contentModificationDate`
    /// — directory kqueue notifications miss child-content edits, and
    /// polling a ≤20-file applet folder is honest and cheap. Started once,
    /// alongside the webview; `stopAgent()` invalidates it.
    private func startHotReloadTimerIfNeeded() {
        guard hotReloadTimer == nil else { return }
        lastKnownModificationDate = Self.maxContentModificationDate(in: applet.folderURL)
        // Self-canceling: the run loop retains the timer (not the session),
        // so a session dropped without `stopAgent()` would otherwise leave
        // a phantom 1 Hz poller firing forever. `deinit` can't invalidate
        // it — a @MainActor class's deinit is nonisolated under Swift 6 —
        // so the first tick after deallocation kills the timer instead.
        hotReloadTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor in
                self.checkForChanges()
            }
        }
    }

    private func checkForChanges() {
        guard _webView != nil else { return }
        let current = Self.maxContentModificationDate(in: applet.folderURL)
        guard current != lastKnownModificationDate else { return }
        lastKnownModificationDate = current
        reload()
    }

    /// Latest `contentModificationDate` across the folder's regular files,
    /// or nil for an empty/missing folder.
    nonisolated private static func maxContentModificationDate(in folderURL: URL) -> Date? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ) else { return nil }

        var latest: Date?
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
            ), values.isRegularFile == true, let modified = values.contentModificationDate
            else { continue }
            if latest == nil || modified > latest! {
                latest = modified
            }
        }
        return latest
    }
}

/// Nav lockdown for the applet preview: only the applet's own
/// `dreamux-applet:` scheme (and `about:`, for the webview's initial blank
/// frame) navigate in place. `http`/`https` links hand off to the user's
/// real browser instead of turning the preview into a browser tab;
/// everything else is refused outright.
///
/// A plain `NSObject`, held **strongly** by `AppletSession` —
/// `WKWebView.navigationDelegate` is a weak reference, so nothing else
/// would keep this alive.
final class AppletNavigationPolicy: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme else { return .cancel }
        switch scheme {
        case AppletSchemeHandler.scheme, "about":
            return .allow
        case "http", "https":
            NSWorkspace.shared.open(url)
            return .cancel
        default:
            return .cancel
        }
    }
}
