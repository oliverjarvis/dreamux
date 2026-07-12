import Foundation

/// The bundled template a new applet starts from: a buildless HTML/JS
/// folder (vendored Preact + htm, a `window.dreamux` bridge shim, and the
/// APPLET.md reference doc) plus the manifest writer and the builder
/// agent's kickoff prompt.
enum AppletScaffold {
    /// The bundled `AppletScaffold` resource folder shipped inside the app.
    static var bundledRoot: URL {
        guard let url = Bundle.module.url(forResource: "AppletScaffold", withExtension: nil) else {
            fatalError("AppletScaffold resource bundle is missing — check Package.swift resources")
        }
        return url
    }

    /// Files copied verbatim (byte-for-byte) from the bundled scaffold.
    private static let verbatimFiles = ["dreamux.js", "preact.mjs", "htm.mjs", "APPLET.md"]

    /// Write a fresh applet at `folderURL`: every bundled scaffold file
    /// (with `{{NAME}}` in index.html replaced by the manifest's name),
    /// plus `manifest.json`.
    static func write(to folderURL: URL, manifest: AppletManifest) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        for file in verbatimFiles {
            let source = bundledRoot.appendingPathComponent(file)
            let destination = folderURL.appendingPathComponent(file)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }

        let templateHTML = try String(contentsOf: bundledRoot.appendingPathComponent("index.html"), encoding: .utf8)
        let substitutedHTML = templateHTML.replacingOccurrences(of: "{{NAME}}", with: manifest.name)
        try substitutedHTML.write(to: folderURL.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        try manifest.write(to: folderURL)
    }

    /// The builder agent's first prompt.
    static func kickoffPrompt(appletName: String, description: String) -> String {
        """
        You are building a Dreamux applet named "\(appletName)" — a small, buildless \
        web tool rendered inside the Dreamux app. Read APPLET.md in this folder FIRST: \
        it documents the applet format and the window.dreamux native bridge.
        Rules: edit files in THIS folder only. Keep it buildless (plain ES modules; \
        preact + htm are vendored here). Update manifest.json's requiresCapabilities \
        to exactly the capabilities you call. The preview hot-reloads on every save.
        If the app calls an authenticated API — most SaaS/dev services (GitHub, \
        Cloudflare, Linear, Stripe, OpenAI, …) — do NOT hardcode a token, read one \
        from the environment, or build your own token-entry field. Instead declare a \
        Connection slot in manifest.json's requiresConnections with a FULL recipe, \
        working out the details yourself from what you know about the service: its \
        `authKind` (usually a Bearer header — `Authorization` / `Bearer {token}` — to \
        the service's API host), its `hosts` (the exact API host, e.g. \
        `api.cloudflare.com`), and an `importCommand` ONLY if the service has a CLI \
        that prints a token (e.g. `gh auth token`; most services don't — then omit \
        it and the user pastes a token). Call the API with \
        `dreamux.http.fetch(url, { connection: "<slot id>" })`; the bridge attaches \
        the credential and the user binds the slot on first open. The user shouldn't \
        have to tell you any of the auth details — infer them. See APPLET.md's \
        `dreamux.connections` section for the exact recipe shapes.
        The user wants: \(description)
        Build it now.
        """
    }
}
