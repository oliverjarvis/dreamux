import Foundation

/// Errors from `ConnectionAuthenticator`. The security boundary for
/// attaching a Connection's credential to a request or shell env.
enum ConnectionAuthError: Error, Equatable {
    case notHTTPS            // authenticated fetch attempted over cleartext
    case hostNotAllowed(String)
    case wrongKindForHTTP    // .env kind used with http.fetch
    case wrongKindForShell   // non-.env kind used with shell.exec
    case malformedURL
}

/// Pure functions that attach a Connection's token to a request (HTTP
/// kinds) or expose it as shell env vars (`.env`). This is THE security
/// boundary: https-only, exact-host allowlist, and kind/context matching
/// are enforced here and nowhere else — no IO, no actor, no WebKit.
enum ConnectionAuthenticator {
    /// Case-insensitive EXACT host match against the allowlist. No suffix
    /// or subdomain matching.
    static func hostAllowed(_ url: URL, hosts: [String]) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let allowed = hosts.map { $0.lowercased() }
        return allowed.contains(host)
    }

    /// Apply an HTTP kind's credential to `request` for `url`. Enforces
    /// https-only and the exact-host allowlist; rejects `.env`. Returns the
    /// mutated request (header set, or query param appended).
    static func authorize(
        _ request: URLRequest, url: URL, kind: AuthKind,
        token: String, hosts: [String]
    ) throws -> URLRequest {
        guard url.scheme?.lowercased() == "https" else {
            throw ConnectionAuthError.notHTTPS
        }
        guard hostAllowed(url, hosts: hosts) else {
            throw ConnectionAuthError.hostNotAllowed(url.host ?? "")
        }

        var request = request
        switch kind {
        case .header(let headerName, let valueTemplate):
            let value = valueTemplate.replacingOccurrences(of: "{token}", with: token)
            request.setValue(value, forHTTPHeaderField: headerName)
            return request

        case .basic(let username):
            let credentials = Data("\(username):\(token)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            return request

        case .query(let param):
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw ConnectionAuthError.malformedURL
            }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: param, value: token))
            components.queryItems = items
            guard let newURL = components.url else {
                throw ConnectionAuthError.malformedURL
            }
            request.url = newURL
            return request

        case .env:
            throw ConnectionAuthError.wrongKindForHTTP
        }
    }

    /// Env additions for a `.env` kind (each var = token). Rejects HTTP kinds.
    static func env(for kind: AuthKind, token: String) throws -> [String: String] {
        guard case .env(let vars) = kind else {
            throw ConnectionAuthError.wrongKindForShell
        }
        return Dictionary(uniqueKeysWithValues: vars.map { ($0, token) })
    }
}
