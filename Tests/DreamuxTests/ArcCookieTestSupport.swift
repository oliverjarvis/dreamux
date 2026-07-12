import Foundation
import CommonCrypto
@testable import Dreamux

/// Test-only: build a Chromium `v10` blob the way Arc would — AES-128-CBC with
/// the fixed all-spaces IV, prefixed with "v10" — so decryptor/source tests can
/// round-trip against a known key without a real Arc install.
func aesCBCEncryptV10(_ plaintext: String, key: Data) -> Data {
    let iv = [UInt8](repeating: 0x20, count: 16)
    let inputBytes = Array(plaintext.utf8)
    var out = [UInt8](repeating: 0, count: inputBytes.count + kCCBlockSizeAES128)
    var moved = 0
    let status = key.withUnsafeBytes { keyPtr in
        CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            keyPtr.baseAddress, key.count,
            iv,
            inputBytes, inputBytes.count,
            &out, out.count,
            &moved
        )
    }
    precondition(status == kCCSuccess, "test encrypt failed")
    return Data("v10".utf8) + Data(out.prefix(moved))
}
