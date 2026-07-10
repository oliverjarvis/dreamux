import Foundation

/// How a Connection's token is applied to a request or a shell env.
enum AuthKind: Codable, Equatable, Sendable {
    /// value = valueTemplate with "{token}" substituted, set on `headerName`.
    /// (Bearer: name "Authorization", template "Bearer {token}";
    ///  GitHub classic PAT: "Authorization" / "token {token}";
    ///  API key: "X-API-Key" / "{token}".)
    case header(headerName: String, valueTemplate: String)
    /// HTTP Basic: header "Authorization" = "Basic base64(username:token)".
    case basic(username: String)
    /// Append `param`={token} to the URL query (legacy APIs).
    case query(param: String)
    /// Inject each of `vars` = token into a single `shell.exec` process env.
    case env(vars: [String])

    /// True if this kind attaches to an HTTP request (header/basic/query);
    /// false for `.env` (shell only).
    var isHTTP: Bool {
        switch self {
        case .header, .basic, .query: return true
        case .env: return false
        }
    }
}

/// A named credential. The secret lives in the Keychain (keyed by `id`);
/// this is the non-secret metadata persisted to `connections.json`.
struct Connection: Identifiable, Codable, Equatable, Sendable {
    let id: String            // slug, unique within the store
    var label: String
    var kind: AuthKind
    var hosts: [String]       // ENFORCED allowlist (lowercased at use)
    var source: Source
    var createdAt: Date

    enum Source: Codable, Equatable, Sendable {
        case manual
        case importedFromCLI(tool: String)   // "gh", "eas"
        case oauth                            // reserved (deferred)
    }
}

/// A manifest-declared connection requirement. Carries no secret.
struct ConnectionSlot: Codable, Equatable, Sendable {
    let id: String            // slot name the applet passes at { connection: id }
    var label: String
    var hosts: [String]       // advisory: what the applet intends to call
    var suggests: String?     // provider hint for the bind UI ("github"/"expo")
}
