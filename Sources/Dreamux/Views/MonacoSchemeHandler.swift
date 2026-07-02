import Foundation
import WebKit

/// Serves the vendored Monaco editor assets to a `WKWebView` over the
/// custom `app-monaco://` scheme. A custom scheme (rather than `file://`)
/// is required so Monaco's language-service web workers load without
/// cross-origin/worker restrictions.
///
/// URL shape: `app-monaco://app/<path>` → `<Monaco resource dir>/<path>`.
final class MonacoSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "app-monaco"

    /// Root of the bundled Monaco assets (the copied `Resources/Monaco`
    /// directory inside the SwiftPM resource bundle).
    static var bundledRoot: URL {
        Bundle.module.url(forResource: "Monaco", withExtension: nil)!
    }

    private let root: URL

    override convenience init() {
        self.init(root: MonacoSchemeHandler.bundledRoot)
    }

    init(root: URL) {
        self.root = root
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let relative = Self.relativePath(for: url) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let fileURL = root.appendingPathComponent(relative)
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

    /// `app-monaco://app/vs/loader.js` → `vs/loader.js`. A bare host maps
    /// to `index.html`. Non-`app-monaco` URLs return nil.
    static func relativePath(for url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        return path.isEmpty ? "index.html" : path
    }

    static func mimeType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "json", "map": return "application/json"
        case "ttf": return "font/ttf"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}
