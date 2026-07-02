import AppKit
import Foundation
import Observation
import WebKit

/// Which face a multi-mode file tab is showing. `.rendered` and
/// `.table` are the read views (MarkdownUI / NSTableView); `.source`
/// is the Monaco editor and is the only mode that can produce edits.
enum FileTabViewMode: String, Sendable {
    case rendered, source, table
}

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
    /// Whether the tab can render its file. Monaco-backed kinds (code/
    /// markdown/tabular): the file decodes as UTF-8 under the 2 MB cap.
    /// Media kinds (image/video/audio/pdf/officePreview): the file
    /// exists — contents are never read into memory here. False shows
    /// the placeholder view.
    let isSupported: Bool

    let kind: FileTabKind
    var viewMode: FileTabViewMode
    /// The file's text as this session last knew it: disk contents at
    /// init, updated on every save and by `refreshCurrentTextFromEditor`.
    /// Read views (markdown preview, CSV table) render from this; empty
    /// for media kinds, which never read the file into memory.
    private(set) var currentText: String
    /// Placeholder escape hatch: render an unsupported file with Quick
    /// Look instead. Sticky per session so the choice survives redraws.
    var useQuickLookFallback = false

    private nonisolated static let maxBytes = 2 * 1024 * 1024

    @ObservationIgnored private var _webView: WKWebView?
    /// One handler serves every editor tab's assets.
    @ObservationIgnored private static let schemeHandler = MonacoSchemeHandler()

    init(fileURL: URL) {
        let resolved = fileURL.resolvingSymlinksInPath()
        self.fileURL = resolved
        self.title = resolved.lastPathComponent
        let kind = FileTabKind.kind(forPathExtension: resolved.pathExtension)
        self.kind = kind
        self.viewMode = Self.defaultViewMode(for: kind)
        if kind.isMonacoBacked {
            let loaded = Self.readText(at: resolved)
            self.currentText = loaded ?? ""
            self.isSupported = loaded != nil
        } else {
            self.currentText = ""
            self.isSupported = FileManager.default.fileExists(atPath: resolved.path)
        }
    }

    nonisolated static func defaultViewMode(for kind: FileTabKind) -> FileTabViewMode {
        switch kind {
        case .markdown: return .rendered
        case .tabular: return .table
        default: return .source
        }
    }

    /// Pull the live Monaco buffer into `currentText` so a rendered
    /// view reflects unsaved edits. No-op when the editor was never
    /// opened (nothing can have changed).
    func refreshCurrentTextFromEditor() {
        guard let _webView else { return }
        _webView.evaluateJavaScript("window.__getValue()") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let text = result as? String else { return }
                self.currentText = text
            }
        }
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
            + "\(Self.jsString(currentText)), "
            + "\(Self.jsString(fileURL.pathExtension)), "
            + "\(Self.jsString(Self.currentTheme())));"
        _webView?.evaluateJavaScript(js)
    }

    private func handleSave(text: String) {
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            currentText = text
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
