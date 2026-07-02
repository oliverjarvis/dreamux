import AppKit
import Foundation
import Observation
import WebKit

/// State behind one Monaco editor tab. Mirrors `WebTabSession`: a lazily
/// built `WKWebView` (here hosting the vendored Monaco editor over the
/// `app-monaco://` scheme) plus dirty tracking and ⌘S save back to the
/// worktree file. A tab id maps to exactly one of the three session
/// kinds (terminal / web / file) in `WorkspaceSession`.
@MainActor
@Observable
final class FileEditorTabSession: Identifiable {
    let id = UUID()
    /// Absolute, symlink-resolved path of the edited file. Dedup key.
    let fileURL: URL
    var title: String
    var isDirty = false
    /// False when the file can't be shown in a text editor (binary or
    /// larger than the cap); the view shows a placeholder instead.
    let isSupported: Bool

    private let contents: String
    private nonisolated static let maxBytes = 2 * 1024 * 1024

    @ObservationIgnored private var _webView: WKWebView?
    /// One handler serves every editor tab's assets.
    @ObservationIgnored private static let schemeHandler = MonacoSchemeHandler()

    init(fileURL: URL) {
        let resolved = fileURL.resolvingSymlinksInPath()
        self.fileURL = resolved
        self.title = resolved.lastPathComponent
        let loaded = Self.readText(at: resolved)
        self.contents = loaded ?? ""
        self.isSupported = loaded != nil
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

    // MARK: - Pure helpers (unit-tested)

    /// Read a file as UTF-8 if it's within the size cap and decodes as
    /// text; nil for binary/oversized files.
    nonisolated static func readText(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= maxBytes else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Encode a Swift string as a JS string literal (quotes + escapes) so
    /// it can be interpolated into an `evaluateJavaScript` call.
    nonisolated static func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let json = String(data: data, encoding: .utf8)!   // ["…"]
        return String(json.dropFirst().dropLast())          // strip surrounding [ ]
    }

    static func currentTheme() -> String {
        let match = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? "vs-dark" : "vs"
    }

    // MARK: - Bridge handling

    private func handleReady() {
        let js = "window.__setContents("
            + "\(Self.jsString(contents)), "
            + "\(Self.jsString(fileURL.pathExtension)), "
            + "\(Self.jsString(Self.currentTheme())));"
        _webView?.evaluateJavaScript(js)
    }

    private func handleSave(text: String) {
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            NSSound.beep()
        }
    }

    /// Separate NSObject so the session itself needn't inherit NSObject;
    /// holds the owner weakly to avoid a webView→config→controller→handler
    /// retain cycle.
    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var owner: FileEditorTabSession?
        init(owner: FileEditorTabSession) { self.owner = owner }
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            MainActor.assumeIsolated {
                guard let owner else { return }
                switch type {
                case "ready": owner.handleReady()
                case "dirty": owner.isDirty = (body["value"] as? Bool) ?? false
                case "save": owner.handleSave(text: (body["text"] as? String) ?? "")
                default: break
                }
            }
        }
    }
}
