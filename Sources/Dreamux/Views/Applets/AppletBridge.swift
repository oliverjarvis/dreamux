import Foundation
import WebKit

/// The `WKScriptMessageHandler` half of the native `window.dreamux` bridge:
/// parses each posted message, gates it against the owning session's
/// granted capabilities, dispatches to `AppletDataStore`/`AppletShell`/
/// networking/notifications, and replies through `window.__dreamuxReply`.
///
/// Holds its owner **weakly**, mirroring `FileEditorTabSession.Bridge`: the
/// retain chain runs `webView` → `configuration` → `userContentController`
/// → this handler, and the owning `AppletSession` owns the `webView` — a
/// strong reference back here would close that into a cycle that never
/// deallocates.
final class AppletBridge: NSObject, WKScriptMessageHandler {
    private weak var owner: AppletSession?

    init(owner: AppletSession) {
        self.owner = owner
        super.init()
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WKWebView delivers script messages on the main thread; this
        // asserts that rather than hopping, matching the
        // `FileEditorTabSession.Bridge` precedent.
        MainActor.assumeIsolated {
            guard let owner else { return }
            guard let body = message.body as? [String: Any] else { return }

            // The injected error-forwarding WKUserScript posts
            // `{method:'__error', text:…}` with no `id` — it isn't a
            // request/reply pair, just a fire-and-forget report.
            if body["method"] as? String == "__error" {
                owner.lastJSError = body["text"] as? String
                return
            }

            guard let request = BridgeRequest.parse(body) else { return }
            Self.dispatch(request, owner: owner)
        }
    }

    // MARK: - Dispatch

    @MainActor
    private static func dispatch(_ request: BridgeRequest, owner: AppletSession) {
        do {
            try AppletBridgeCore.checkAllowed(
                method: request.method,
                granted: owner.applet.manifest.grantedCapabilities
            )
        } catch {
            reply(id: request.id, owner: owner, error: error)
            return
        }

        switch request.method {
        case "context":
            reply(id: request.id, owner: owner, result: [
                "projectName": owner.projectRoot.lastPathComponent,
                "projectRoot": owner.projectRoot.path,
                "dataDir": owner.dataStore.dataDir.path,
            ])

        case "kv.get":
            guard let key = request.params["key"] as? String else {
                reply(id: request.id, owner: owner, error: AppletBridgeError.badParams("key"))
                return
            }
            reply(id: request.id, owner: owner, result: owner.dataStore.kvGet(key) ?? NSNull())

        case "kv.set":
            guard let key = request.params["key"] as? String else {
                reply(id: request.id, owner: owner, error: AppletBridgeError.badParams("key"))
                return
            }
            let value = request.params["value"] ?? NSNull()
            do {
                try owner.dataStore.kvSet(key, value: value)
                reply(id: request.id, owner: owner, result: NSNull())
            } catch {
                reply(id: request.id, owner: owner, error: error)
            }

        case "kv.delete":
            guard let key = request.params["key"] as? String else {
                reply(id: request.id, owner: owner, error: AppletBridgeError.badParams("key"))
                return
            }
            do {
                try owner.dataStore.kvDelete(key)
                reply(id: request.id, owner: owner, result: NSNull())
            } catch {
                reply(id: request.id, owner: owner, error: error)
            }

        case "kv.list":
            // The shim documents `kv.list()` as the list of *keys*, not
            // the stored values.
            reply(id: request.id, owner: owner, result: Array(owner.dataStore.kvList().keys).sorted())

        case "fs.read":
            guard let path = nonEmptyPath(request) else {
                reply(id: request.id, owner: owner, error: AppletBridgeError.badParams("path"))
                return
            }
            do {
                reply(id: request.id, owner: owner, result: try owner.dataStore.fsRead(path))
            } catch {
                reply(id: request.id, owner: owner, error: error)
            }

        case "fs.write":
            guard let path = nonEmptyPath(request), let text = request.params["text"] as? String else {
                reply(id: request.id, owner: owner, error: AppletBridgeError.badParams("path/text"))
                return
            }
            do {
                try owner.dataStore.fsWrite(path, text: text)
                reply(id: request.id, owner: owner, result: NSNull())
            } catch {
                reply(id: request.id, owner: owner, error: error)
            }

        case "fs.list":
            // Empty path IS allowed here — it lists the files/ root, and
            // the shim's default (`path || ''`) sends exactly that.
            let path = request.params["path"] as? String ?? ""
            do {
                reply(id: request.id, owner: owner, result: try owner.dataStore.fsList(path))
            } catch {
                reply(id: request.id, owner: owner, error: error)
            }

        case "fs.delete":
            guard let path = nonEmptyPath(request) else {
                reply(id: request.id, owner: owner, error: AppletBridgeError.badParams("path"))
                return
            }
            do {
                try owner.dataStore.fsDelete(path)
                reply(id: request.id, owner: owner, result: NSNull())
            } catch {
                reply(id: request.id, owner: owner, error: error)
            }

        case "http.fetch":
            guard let urlString = request.params["url"] as? String, let url = URL(string: urlString) else {
                reply(id: request.id, owner: owner, error: AppletBridgeError.badParams("url"))
                return
            }
            let method = request.params["method"] as? String ?? "GET"
            let headers = request.params["headers"] as? [String: String] ?? [:]
            let bodyText = request.params["body"] as? String
            let connectionSlot = (request.params["connection"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            Task { @MainActor [weak owner] in
                guard let owner else { return }
                do {
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = method
                    for (field, value) in headers {
                        urlRequest.setValue(value, forHTTPHeaderField: field)
                    }
                    if let bodyText {
                        urlRequest.httpBody = Data(bodyText.utf8)
                    }
                    // A bound connection's credential is attached natively here
                    // — AFTER the applet's own headers, so it wins on any shared
                    // field — and ONLY through `ConnectionAuthenticator` (the
                    // https-only / host-allowlist boundary). This sits inside
                    // the do-block and BEFORE the URLSession call: any
                    // resolve/authorize throw jumps to the catch below, so the
                    // request is never sent and the token never leaves this line.
                    if let connectionSlot {
                        let resolved = try owner.connections.resolve(slot: connectionSlot)
                        urlRequest = try ConnectionAuthenticator.authorize(
                            urlRequest, url: url, kind: resolved.connection.kind,
                            token: resolved.token, hosts: resolved.connection.hosts)
                    }
                    let (data, response) = try await URLSession.shared.data(for: urlRequest)
                    let http = response as? HTTPURLResponse
                    var responseHeaders: [String: String] = [:]
                    for (field, value) in http?.allHeaderFields ?? [:] {
                        responseHeaders["\(field)"] = "\(value)"
                    }
                    reply(id: request.id, owner: owner, result: [
                        "status": http?.statusCode ?? 0,
                        "headers": responseHeaders,
                        "text": String(data: data, encoding: .utf8) ?? "",
                    ])
                } catch {
                    reply(id: request.id, owner: owner, error: error)
                }
            }

        case "shell.exec":
            guard let cmd = request.params["cmd"] as? String else {
                reply(id: request.id, owner: owner, error: AppletBridgeError.badParams("cmd"))
                return
            }
            let cwd = (request.params["cwd"] as? String).map(URL.init(fileURLWithPath:)) ?? owner.projectRoot
            let timeout = request.params["timeout"] as? Double ?? 60
            let connectionSlot = (request.params["connection"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            Task { @MainActor [weak owner] in
                guard let owner else { return }
                // A `.env`-kind connection injects its token as process env
                // vars (via `ConnectionAuthenticator.env`). Resolve/env failures
                // abort BEFORE exec — nothing runs without the credential the
                // applet asked for, and no token reaches a reply. No connection
                // → empty env, unchanged behaviour.
                let connectionEnv: [String: String]
                if let connectionSlot {
                    do {
                        let resolved = try owner.connections.resolve(slot: connectionSlot)
                        connectionEnv = try ConnectionAuthenticator.env(for: resolved.connection.kind, token: resolved.token)
                    } catch {
                        reply(id: request.id, owner: owner, error: error)
                        return
                    }
                } else {
                    connectionEnv = [:]
                }
                let result = await AppletShell.exec(cmd: cmd, cwd: cwd, timeout: timeout, env: connectionEnv)
                reply(id: request.id, owner: owner, result: [
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                    "code": result.code,
                ])
            }

        case "notify":
            guard let title = request.params["title"] as? String else {
                reply(id: request.id, owner: owner, error: AppletBridgeError.badParams("title"))
                return
            }
            let body = request.params["body"] as? String ?? ""
            NotificationManager.shared.notify(title: title, body: body)
            reply(id: request.id, owner: owner, result: NSNull())

        case "connections.status":
            // Non-secret snapshot only — never a token. Capability-free.
            guard let slot = request.params["slot"] as? String, !slot.isEmpty else {
                reply(id: request.id, owner: owner, error: AppletBridgeError.badParams("slot"))
                return
            }
            let status = owner.connections.status(slot: slot)
            reply(id: request.id, owner: owner, result: [
                "bound": status.bound,
                "label": status.label ?? NSNull(),
                "hosts": status.hosts,
            ])

        case "connections.request":
            // Opens the host-view bind sheet and awaits its dismissal, then
            // replies with the resulting (still non-secret) status.
            guard let slot = request.params["slot"] as? String, !slot.isEmpty else {
                reply(id: request.id, owner: owner, error: AppletBridgeError.badParams("slot"))
                return
            }
            Task { @MainActor [weak owner] in
                guard let owner else { return }
                let status = await owner.requestBind(slot: slot)
                reply(id: request.id, owner: owner, result: [
                    "bound": status.bound,
                    "label": status.label ?? NSNull(),
                    "hosts": status.hosts,
                ])
            }

        default:
            // Unreachable in practice: `checkAllowed` above already threw
            // `unknownMethod` for anything outside `AppletBridgeCore
            // .knownMethods`, and every entry in that set has a case
            // above. Kept as a non-crashing fallback rather than an
            // exhaustiveness trap.
            reply(id: request.id, owner: owner, error: AppletBridgeError.unknownMethod(request.method))
        }
    }

    /// `path` trimmed to a non-empty String, or nil. Shared by fs.read/
    /// fs.write/fs.delete: an empty path there would resolve to the
    /// applet's whole `files/` root — for `fs.delete` that means wiping
    /// the entire sandbox, so it's rejected as a bad param rather than
    /// silently passed through (fs.list is the one method that treats
    /// empty as "the root", handled separately above).
    private static func nonEmptyPath(_ request: BridgeRequest) -> String? {
        guard let path = request.params["path"] as? String, !path.isEmpty else { return nil }
        return path
    }

    // MARK: - Reply

    /// Every reply — success or failure — round-trips through
    /// `JSONSerialization`. `result`/`error` values built from native data
    /// (file contents, process output, HTTP bodies) are always plist-safe
    /// today, but a handler could change that later — if serialization
    /// ever fails, fall back to an `{error}` reply instead of crashing or
    /// leaving the JS side's promise pending forever.
    @MainActor
    private static func reply(id: Int, owner: AppletSession, result: Any) {
        replyJSON(id: id, owner: owner, envelope: ["result": result])
    }

    @MainActor
    private static func reply(id: Int, owner: AppletSession, error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        replyJSON(id: id, owner: owner, envelope: ["error": message])
    }

    @MainActor
    private static func replyJSON(id: Int, owner: AppletSession, envelope: [String: Any]) {
        let json: String
        if JSONSerialization.isValidJSONObject(envelope),
           let data = try? JSONSerialization.data(withJSONObject: envelope),
           let encoded = String(data: data, encoding: .utf8) {
            json = encoded
        } else {
            json = #"{"error":"internal: reply payload was not JSON-serializable"}"#
        }
        owner.webView.evaluateJavaScript("window.__dreamuxReply(\(id), \(json))")
    }
}
