import Foundation

/// Composes the app-wide `ConnectionStore` with a single applet's
/// `ConnectionBindingStore` to answer the one question the bridge asks on
/// every `{connection}`-tagged `http.fetch`/`shell.exec`: which live
/// `Connection` — and its secret token — is this applet's declared slot
/// bound to?
///
/// This is a *composition* seam, NOT a new security boundary. The token it
/// returns is handed straight to `ConnectionAuthenticator` (the single place
/// https-only / exact-host-allowlist / kind matching is enforced) and never
/// enters a bridge reply, a log line, or any on-disk store.
@MainActor
final class AppletConnectionResolver {
    /// App-wide connection registry (metadata + secret access).
    let store: ConnectionStore
    /// This applet's slot→connectionId map. Exposed so the host view / bind
    /// sheet (T8) mutate the SAME instance the resolver reads.
    let bindings: ConnectionBindingStore

    init(store: ConnectionStore, bindings: ConnectionBindingStore) {
        self.store = store
        self.bindings = bindings
    }

    /// Non-secret snapshot of a slot's binding, for the bind UI and the
    /// capability-free `connections.status` bridge method. A binding that
    /// points at a since-deleted connection reads as `bound: false` — it
    /// needs re-binding, exactly like a slot that was never bound.
    struct Status: Equatable {
        var bound: Bool
        var label: String?
        var hosts: [String]
    }

    func status(slot: String) -> Status {
        guard let id = bindings.connectionID(forSlot: slot),
              let connection = store.connection(id: id) else {
            return Status(bound: false, label: nil, hosts: [])
        }
        return Status(bound: true, label: connection.label, hosts: connection.hosts)
    }

    /// A resolved binding: live connection metadata plus its secret token,
    /// read fresh from the SecretStore. The token is for immediate hand-off
    /// to `ConnectionAuthenticator` only — it must not be stored or replied.
    struct Resolved {
        let connection: Connection
        let token: String
    }

    /// Every case carries the *slot* name so the applet-facing error stays in
    /// the applet's own vocabulary (it knows slots, not internal connection ids).
    enum ResolveError: Error, Equatable {
        case slotNotBound(String)
        case connectionMissing(String)
        case tokenMissing(String)
    }

    /// slot → binding → connection (+ token). Throws — never returns a
    /// partial or placeholder — if the slot is unbound, its bound connection
    /// was deleted, or the secret is gone.
    func resolve(slot: String) throws -> Resolved {
        guard let id = bindings.connectionID(forSlot: slot) else {
            throw ResolveError.slotNotBound(slot)
        }
        guard let connection = store.connection(id: id) else {
            throw ResolveError.connectionMissing(slot)
        }
        guard let token = store.token(for: id) else {
            throw ResolveError.tokenMissing(slot)
        }
        return Resolved(connection: connection, token: token)
    }
}
