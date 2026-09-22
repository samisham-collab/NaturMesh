import Foundation
import CryptoKit
import Security

/// One Ed25519 key per device, kept in the Keychain. Every packet this device sends is signed with it.
/// A second, X25519 key handles end-to-end direct messages. Neither key ever leaves the device.
final class Identity {
    let privateKey: Curve25519.Signing.PrivateKey
    let agreementKey: Curve25519.KeyAgreement.PrivateKey
    var publicKeyData: Data { privateKey.publicKey.rawRepresentation }
    var agreementPublicKeyData: Data { agreementKey.publicKey.rawRepresentation }
    lazy var nodeID = NodeID(publicKey: publicKeyData)

    private static let service = "org.naturmesh.identity"
    private static let signingAccount = "signing-key-v1"
    private static let agreementAccount = "agreement-key-v1"

    static func loadOrCreate() -> Identity {
        let signing: Curve25519.Signing.PrivateKey
        if let raw = Keychain.read(service: service, account: signingAccount),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            signing = key
        } else {
            signing = Curve25519.Signing.PrivateKey()
            Keychain.write(signing.rawRepresentation, service: service, account: signingAccount)
        }
        let agreement: Curve25519.KeyAgreement.PrivateKey
        if let raw = Keychain.read(service: service, account: agreementAccount),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            agreement = key
        } else {
            agreement = Curve25519.KeyAgreement.PrivateKey()
            Keychain.write(agreement.rawRepresentation, service: service, account: agreementAccount)
        }
        return Identity(privateKey: signing, agreementKey: agreement)
    }

    private init(privateKey: Curve25519.Signing.PrivateKey, agreementKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
        self.agreementKey = agreementKey
    }

    func sign(_ data: Data) throws -> Data { try privateKey.signature(for: data) }

    /// Pair key for direct messages with `peerAgreementKey`. Both sides derive the same key.
    func pairKey(with peerAgreementKey: Data) -> SymmetricKey? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerAgreementKey),
              let shared = try? agreementKey.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        let mine = agreementPublicKeyData
        let info = mine.lexicographicallyPrecedes(peerAgreementKey) ? mine + peerAgreementKey : peerAgreementKey + mine
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("NaturMesh-dm-v1".utf8), sharedInfo: info, outputByteCount: 32)
    }

    static func verify(signature: Data, of data: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

enum Keychain {
    static func read(service: String, account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func write(_ data: Data, service: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
