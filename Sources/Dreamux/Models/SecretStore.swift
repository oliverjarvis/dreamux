import Foundation
import Security

/// Stores/retrieves a connection's raw token, keyed by connection id. The
/// only component that ever holds a plaintext token at rest.
protocol SecretStore: Sendable {
    func set(_ token: String, for id: String) throws
    func get(_ id: String) -> String?
    func delete(_ id: String) throws
}

enum SecretStoreError: LocalizedError {
    case unsafeID(String)
    case keychain(OSStatus, operation: String)

    var errorDescription: String? {
        switch self {
        case .unsafeID(let id):
            return "“\(id)” isn't a safe connection id for a secret file."
        case .keychain(let status, let operation):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            return "Keychain \(operation) failed: \(message)"
        }
    }
}

/// macOS Keychain generic-password store (app default). One item per
/// connection id: `kSecClassGenericPassword`, this `service`, `account`
/// set to the id, readable only `kSecAttrAccessibleWhenUnlocked`.
struct KeychainSecretStore: SecretStore {
    var service = "com.dreamux.Dreamux.connection"

    private func baseQuery(for id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
    }

    func set(_ token: String, for id: String) throws {
        let data = Data(token.utf8)
        var addQuery = baseQuery(for: id)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw SecretStoreError.keychain(addStatus, operation: "add")
        }

        let updateQuery = baseQuery(for: id)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw SecretStoreError.keychain(updateStatus, operation: "update")
        }
    }

    func get(_ id: String) -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    func delete(_ id: String) throws {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status, operation: "delete")
        }
    }
}

/// File-backed store: one 0600 file per id under `dir`. Selected ONLY when
/// `$DREAMUX_CONNECTIONS_SECRET_DIR` is set (tests/e2e) — never the Keychain
/// in that mode.
struct FileSecretStore: SecretStore {
    let dir: URL   // created on demand

    /// `id` keys a filename appended straight to `dir`, so it's guarded with
    /// the same `AppletSlug.isSafe` chokepoint every other id-as-path-component
    /// use in this app goes through — rejects "/", "..", and anything else
    /// that could traverse out of `dir`.
    private func fileURL(for id: String) throws -> URL {
        guard AppletSlug.isSafe(id) else {
            throw SecretStoreError.unsafeID(id)
        }
        return dir.appendingPathComponent(id, isDirectory: false)
    }

    func set(_ token: String, for id: String) throws {
        let url = try fileURL(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(token.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func get(_ id: String) -> String? {
        guard let url = try? fileURL(for: id),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ id: String) throws {
        let url = try fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// In-memory (unit tests).
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func set(_ token: String, for id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[id] = token
    }

    func get(_ id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    func delete(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: id)
    }
}

enum SecretStoreFactory {
    /// `FileSecretStore(dir:)` when `$DREAMUX_CONNECTIONS_SECRET_DIR` is set
    /// to a non-empty value (tests/e2e — mirrors `ProjectStore`'s
    /// `$DREAMUX_*` overrides), else `KeychainSecretStore()`.
    static func makeDefault() -> SecretStore {
        let env = ProcessInfo.processInfo.environment
        if let override = env["DREAMUX_CONNECTIONS_SECRET_DIR"], !override.isEmpty {
            return FileSecretStore(dir: URL(fileURLWithPath: override, isDirectory: true))
        }
        return KeychainSecretStore()
    }
}
