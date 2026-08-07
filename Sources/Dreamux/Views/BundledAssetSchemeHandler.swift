import Foundation
import WebKit

/// Serves a bundled (or on-disk) directory to a `WKWebView` over a custom
/// scheme. One type for all three consumers — Monaco (`app-monaco`), applets
/// (`dreamux-applet`) and the Flows canvas (`dreamux-flows`) — so the
/// traversal guard exists in exactly one place. A custom scheme (rather than
/// `file://`) is required so Monaco's language-service web workers load
/// without cross-origin/worker restrictions.
///
/// URL shape: `<scheme>://<host>/<path>` → `<root>/<path>`; a bare host
/// resolves to `index.html`. The host segment is never used for resolution —
/// an instance is already bound to one root.
final class BundledAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    // `WKURLSchemeHandler` is a @MainActor protocol, so conforming would
    // infer @MainActor for these too. They are immutable strings and pure
    // functions over their arguments — nothing here touches main-actor
    // state, and callers (tests, `AppletNavigationPolicy`) read them from
    // nonisolated contexts.
    nonisolated static let monacoScheme = "app-monaco"
    nonisolated static let appletScheme = "dreamux-applet"
    nonisolated static let flowsScheme = "dreamux-flows"

    private let scheme: String
    private let root: URL

    init(scheme: String, root: URL) {
        self.scheme = scheme
        self.root = root
        super.init()
    }

    /// A copied `Resources/<name>` directory inside the SwiftPM resource
    /// bundle (`.copy` in Package.swift).
    nonisolated static func bundledRoot(named name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil)!
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let fileURL = Self.resolvedFileURL(for: url, root: root, scheme: scheme)
        else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: Self.mimeType(forPathExtension: fileURL.pathExtension),
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// Resolves `url` to a file inside `root`, guarding against traversal
    /// (raw `../` or percent-encoded `%2e%2e/`) and symlink escapes.
    /// Returns nil for a foreign scheme or any resolution landing outside
    /// `root`. An empty path (bare host) resolves to `index.html`.
    nonisolated static func resolvedFileURL(for url: URL, root: URL, scheme: String) -> URL? {
        guard url.scheme == scheme else { return nil }

        // `URL.path` already percent-decodes, so "%2e%2e" and ".." arrive
        // identically here — both get collapsed lexically by
        // `standardizedFileURL` below, and either can walk the candidate
        // outside root before the symlink resolution / prefix check.
        var relative = url.path
        if relative.hasPrefix("/") { relative.removeFirst() }
        relative = relative.isEmpty ? "index.html" : relative

        let candidate = root.appendingPathComponent(relative)
            .standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()

        guard candidate.path == resolvedRoot.path
            || candidate.path.hasPrefix(resolvedRoot.path + "/")
        else {
            return nil
        }
        return candidate
    }

    nonisolated static func mimeType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json", "map": return "application/json"
        case "ttf": return "font/ttf"
        case "svg": return "image/svg+xml"
        case "md": return "text/markdown"
        default: return "application/octet-stream"
        }
    }
}
