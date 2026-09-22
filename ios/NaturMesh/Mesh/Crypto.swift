import Foundation
import CryptoKit

/// A channel is a shared passphrase. Same passphrase = can read. Everyone else still relays.
struct Channel: Equatable {
    let name: String
    let key: SymmetricKey
    /// Four bytes that travel in the clear so receivers know which key to try. Not secret.
    let tag: UInt32

    static let defaultName = "public"

    init(passphrase: String) {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed.isEmpty ? Channel.defaultName : trimmed
        let ikm = SymmetricKey(data: Data(name.lowercased().utf8))
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm,
                                     salt: Data("NaturMesh-channel-v1".utf8),
                                     info: Data("body-key".utf8),
                                     outputByteCount: 32)
        let tagDigest = SHA256.hash(data: key.withUnsafeBytes { Data($0) } + Data("tag".utf8))
        var t: UInt32 = 0
        for b in tagDigest.prefix(4) { t = t << 8 | UInt32(b) }
        tag = t
    }

    static func == (a: Channel, b: Channel) -> Bool { a.tag == b.tag && a.name == b.name }

    func seal(_ plaintext: Data, nonce: Data, aad: Data) throws -> Data {
        let n = try ChaChaPoly.Nonce(data: nonce)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: n, authenticating: aad)
        return box.ciphertext + box.tag
    }

    func open(_ ciphertext: Data, nonce: Data, aad: Data) -> Data? {
        guard ciphertext.count >= Wire.tagBytes else { return nil }
        let body = ciphertext.prefix(ciphertext.count - Wire.tagBytes)
        let tag = ciphertext.suffix(Wire.tagBytes)
        guard let n = try? ChaChaPoly.Nonce(data: nonce),
              let box = try? ChaChaPoly.SealedBox(nonce: n, ciphertext: body, tag: tag) else { return nil }
        return try? ChaChaPoly.open(box, using: key, authenticating: aad)
    }

    static func randomNonce() -> Data {
        var b = [UInt8](repeating: 0, count: Wire.nonceBytes)
        for i in 0..<b.count { b[i] = UInt8.random(in: 0...255) }
        return Data(b)
    }
}

/// End-to-end box for direct messages: nonce + ciphertext + tag under a pair key.
enum DirectBox {
    static func seal(_ plaintext: Data, key: SymmetricKey) -> Data? {
        guard let box = try? ChaChaPoly.seal(plaintext, using: key) else { return nil }
        return box.combined
    }

    static func open(_ combined: Data, key: SymmetricKey) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: combined) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }
}
