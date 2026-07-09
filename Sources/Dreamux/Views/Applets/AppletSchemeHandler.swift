import Foundation
import WebKit

/// Serves an applet folder to its WKWebView over `dreamux-applet://`.
/// URL shape: `dreamux-applet://<applet-id>/<path>`; bare host → index.html.
/// Clone of `MonacoSchemeHandler` plus a traversal guard: the resolved file
/// must stay inside the root. The host segment (the applet id) is not used
/// for resolution — this handler instance is already bound to one folder;
/// validating the id against that binding is not this type's job.
final class AppletSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "dreamux-applet"

    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let fileURL = Self.resolvedFileURL(for: url, root: root)
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
    /// Returns nil for foreign schemes or any resolution landing outside
    /// `root`. An empty path (bare host) resolves to `index.html`.
    static func resolvedFileURL(for url: URL, root: URL) -> URL? {
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

    static func mimeType(forPathExtension ext: String) -> String {
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
