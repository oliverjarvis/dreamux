import Foundation
import CommonCrypto
import Security

/// Decrypts Arc's Chromium `encrypted_value` blobs. The AES key is derived
/// (PBKDF2) from the "Arc Safe Storage" password in the login Keychain, and
/// `v10` values are AES-128-CBC with a fixed all-spaces IV — the standard
/// Chromium-on-macOS scheme. The pure crypto is separate from the one Keychain
/// read so it's unit-testable without a Keychain.
struct ArcCookieDecryptor {
    static let salt = "saltysalt"
    static let iterations: UInt32 = 1003
    static let keyLength = 16                                 // AES-128
    static let iv = [UInt8](repeating: 0x20, count: 16)       // 16 spaces

    /// PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16) → 128-bit AES key.
    static func deriveKey(fromStoragePassword password: String) -> Data {
        let pw = Array(password.utf8)
        let st = Array(salt.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)
        _ = pw.withUnsafeBufferPointer { pwPtr in
            st.withUnsafeBufferPointer { stPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.baseAddress, pwPtr.count,
                    stPtr.baseAddress, stPtr.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    iterations,
                    &derived, derived.count
                )
            }
        }
        return Data(derived)
    }

    /// Decrypt one `encrypted_value`. Returns nil (skip, never crash) for a
    /// version prefix we don't handle (app-bound `v20`, GCM, …) or any crypto
    /// failure.
    static func decrypt(_ blob: Data, key: Data) -> String? {
        guard blob.count > 3,
              String(bytes: blob.prefix(3), encoding: .utf8) == "v10" else { return nil }
        guard let plaintext = aesCBCDecrypt(Data(blob.dropFirst(3)), key: key) else { return nil }
        if let direct = String(data: plaintext, encoding: .utf8) { return direct }
        // Newer Chromium prepends a 32-byte SHA-256 domain hash to the plaintext.
        if plaintext.count > 32,
           let stripped = String(data: plaintext.dropFirst(32), encoding: .utf8) { return stripped }
        return nil
    }

    private static func aesCBCDecrypt(_ data: Data, key: Data) -> Data? {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES128),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyPtr.baseAddress, key.count,
                    iv,
                    dataPtr.baseAddress, data.count,
                    &out, out.count,
                    &moved
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(moved))
    }

    /// The one impure bit: read Arc's storage password from the login Keychain.
    /// This raises the macOS authorization prompt — the consent gate.
    static func copyStoragePassword(
        service: String = "Arc Safe Storage",
        account: String = "Arc"
    ) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                throw CookieImportError.keychainKeyMissing(browser: "Arc")
            }
            return password
        case errSecItemNotFound:
            throw CookieImportError.keychainKeyMissing(browser: "Arc")
        default:
            throw CookieImportError.keychainDenied(browser: "Arc")
        }
    }
}
