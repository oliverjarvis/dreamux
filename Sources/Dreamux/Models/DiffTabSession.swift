import Foundation
import Observation
import WebKit

/// A revision range to diff inside one repo worktree. `toRevision`
/// nil means the working tree — the "Uncommitted changes" row.
struct DiffRequest: Equatable {
    let worktreeURL: URL
    let fromRevision: String
    let toRevision: String?
    let title: String
}

/// One changed file in the diff tab's left rail.
struct DiffFileEntry: Identifiable, Equatable {
    let status: String
    let path: String
    var id: String { path }
}

/// Read-only diff tab: a file list plus a Monaco diff editor. Owns its
/// webview the same way `FileEditorTabSession` does (lazy, retained by
/// the session so pane moves don't reload Monaco), but never writes —
/// there is no save path in or out. A tab id maps to exactly one of
/// the four session kinds (terminal / web / file / diff) in
/// `WorkspaceSession`.
@MainActor
@Observable
final class DiffTabSession {
    let request: DiffRequest
    private(set) var files: [DiffFileEntry] = []
    private(set) var isLoading = true
    var selectedPath: String?

    private var jsReady = false

    @ObservationIgnored private var _webView: WKWebView?
    /// One handler serves every diff tab's assets — same scheme
    /// handler instance FileEditorTabSession uses, since both load the
    /// same vendored Monaco bundle over `app-monaco://`.
    @ObservationIgnored private static let schemeHandler = MonacoSchemeHandler()

    init(request: DiffRequest) {
        self.request = request
        Task { await load() }
    }

    var webView: WKWebView {
        if let _webView { return _webView }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(Self.schemeHandler, forURLScheme: MonacoSchemeHandler.scheme)
        config.userContentController.add(Bridge(owner: self), name: "bridge")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isInspectable = true
        view.load(URLRequest(url: URL(string: "\(MonacoSchemeHandler.scheme)://app/index.html")!))
        _webView = view
        return view
    }

    /// Test seam: run the same load the initializer kicks off, awaitably.
    func loadForTesting() async { await load() }

    private func load() async {
        let changed = await GitOperations.changedFiles(
            from: request.fromRevision,
            to: request.toRevision,
            in: request.worktreeURL)
        files = changed.map { DiffFileEntry(status: $0.status, path: $0.path) }
        isLoading = false
        if selectedPath == nil, let first = files.first?.path {
            selectFile(first)
        }
    }

    /// Both sides of one file's diff. nil side = file absent there
    /// (added/deleted) or binary.
    func contentPair(for path: String) async -> (original: String?, modified: String?) {
        async let original = GitOperations.fileContent(
            at: path, revision: request.fromRevision, in: request.worktreeURL)
        async let modified = GitOperations.fileContent(
            at: path, revision: request.toRevision, in: request.worktreeURL)
        return (await original, await modified)
    }

    func selectFile(_ path: String) {
        selectedPath = path
        Task { await pushSelected() }
    }

    private func pushSelected() async {
        guard jsReady, let path = selectedPath else { return }
        let pair = await contentPair(for: path)
        // Rapid rail navigation must not let a slow earlier fetch
        // overwrite a newer selection.
        guard selectedPath == path else { return }
        let ext = (path as NSString).pathExtension
        pushDiff(original: pair.original ?? "", modified: pair.modified ?? "", ext: ext)
    }

    private func pushDiff(original: String, modified: String, ext: String) {
        let js = "window.__setDiff("
            + "\(FileEditorTabSession.jsString(original)), "
            + "\(FileEditorTabSession.jsString(modified)), "
            + "\(FileEditorTabSession.jsString(ext)), "
            + "\(FileEditorTabSession.jsString(FileEditorTabSession.currentTheme())));"
        _webView?.evaluateJavaScript(js)
    }

    /// Separate NSObject so the session itself needn't inherit NSObject;
    /// holds the owner weakly to avoid a webView→config→controller→handler
    /// retain cycle (same shape as FileEditorTabSession.Bridge).
    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var owner: DiffTabSession?
        init(owner: DiffTabSession) { self.owner = owner }
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  body["type"] as? String == "ready" else { return }
            MainActor.assumeIsolated {
                guard let owner else { return }
                owner.jsReady = true
                Task { await owner.pushSelected() }
            }
        }
    }
}
