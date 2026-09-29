import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

public enum Base64URL {
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// P-256 key encodings shared by every signer.
public enum P256Keys {
    /// DER prefix of SubjectPublicKeyInfo for id-ecPublicKey / prime256v1 (uncompressed point follows).
    static let spkiHeader = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ])

    public static func spki(fromX963 point: Data) throws -> Data {
        guard point.count == 65, point.first == 0x04 else { throw ApproverRefusal("bad_point") }
        return spkiHeader + point
    }

    public static func x963(fromSPKI spki: Data) throws -> Data {
        guard spki.count == 91, spki.prefix(spkiHeader.count) == spkiHeader, spki[spkiHeader.count] == 0x04
        else { throw ApproverRefusal("bad_spki") }
        return Data(spki.dropFirst(spkiHeader.count))
    }

    /// kid = base64url(first 16 bytes of sha256(SPKI DER)), unpadded (22 chars).
    public static func kid(spki: Data) -> String {
        Base64URL.encode(Data(SHA256.hash(data: spki).prefix(16)))
    }
}

/// Strict X9.62 DER ECDSA-Sig-Value: canonical minimal encoding, r and s in 1..n-1, no trailing bytes.
public enum DERSignature {
    static let n: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
    ]

    public static func parseStrict(_ der: Data) -> (r: [UInt8], s: [UInt8])? {
        let b = [UInt8](der)
        guard b.count >= 8, b[0] == 0x30, b[1] < 0x80, Int(b[1]) == b.count - 2 else { return nil }
        var i = 2
        func integer() -> [UInt8]? {
            guard i + 2 <= b.count, b[i] == 0x02 else { return nil }
            let len = Int(b[i + 1])
            guard len >= 1, len < 0x80, i + 2 + len <= b.count else { return nil }
            var v = Array(b[(i + 2)..<(i + 2 + len)])
            i += 2 + len
            if v[0] & 0x80 != 0 { return nil }  // negative
            if v.count > 1, v[0] == 0x00, v[1] & 0x80 == 0 { return nil }  // non-minimal
            if v[0] == 0x00 { v.removeFirst() }
            guard !v.isEmpty, v.contains(where: { $0 != 0 }), v.count <= 32 else { return nil }
            let padded = [UInt8](repeating: 0, count: 32 - v.count) + v
            guard padded.lexicographicallyPrecedes(n) else { return nil }
            return padded
        }
        guard let r = integer(), let s = integer(), i == b.count else { return nil }
        return (r, s)
    }
}

public enum P256Verifier {
    /// Verify an ES256 (ECDSA P-256 / SHA-256, X9.62 DER) signature over `message`.
    public static func verify(spki: Data, message: Data, derSignature: Data) -> Bool {
        guard DERSignature.parseStrict(derSignature) != nil,
              let point = try? P256Keys.x963(fromSPKI: spki),
              let key = try? P256.Signing.PublicKey(x963Representation: point),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: derSignature)
        else { return false }
        return key.isValidSignature(sig, for: message)
    }
}

/// A key that signs only after a human gate. `reason` is the rendered WYSIWYS summary.
public protocol ApprovalSigner {
    var alg: String { get }
    var kid: String { get }
    var publicKeySPKI: Data { get }
    func sign(message: Data, reason: String) throws -> Data
}

/// CI / cross-runtime fixture signer. NOT a human approval: no biometric, exportable key.
/// Refused at runtime unless the dev flag is explicitly enabled.
public final class SoftwareP256Signer: ApprovalSigner {
    public static let devEnvVar = "SA2A_APPROVER_DEV"
    public let alg = "ES256"
    public let publicKeySPKI: Data
    public let kid: String
    public private(set) var lastReason: String?
    private let key: P256.Signing.PrivateKey

    public static func devFlagFromEnvironment() -> Bool {
        ProcessInfo.processInfo.environment[devEnvVar] == "1"
    }

    public init(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
                devFlag: Bool = SoftwareP256Signer.devFlagFromEnvironment()) throws {
        guard devFlag else { throw ApproverRefusal("software_signer_refused") }
        key = privateKey
        publicKeySPKI = try P256Keys.spki(fromX963: privateKey.publicKey.x963Representation)
        kid = P256Keys.kid(spki: publicKeySPKI)
    }

    public var rawPrivateKey: Data { key.rawRepresentation }

    public func sign(message: Data, reason: String) throws -> Data {
        lastReason = reason
        return try key.signature(for: message).derRepresentation
    }
}

#if canImport(Security) && canImport(LocalAuthentication)
/// Secure Enclave P-256 key: non-exportable, biometric-gated (.biometryCurrentSet), signs with
/// SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256) which returns X9.62 DER.
/// UNVERIFIED in this repo's CI: exercising it requires biometrics and a signed app bundle.
public final class SecureEnclaveSigner: ApprovalSigner {
    public let alg = "ES256"
    public let publicKeySPKI: Data
    public let kid: String
    private let privateKey: SecKey
    private let tag: Data

    init(privateKey: SecKey, tag: Data) throws {
        self.privateKey = privateKey
        self.tag = tag
        guard let pub = SecKeyCopyPublicKey(privateKey),
              let ext = SecKeyCopyExternalRepresentation(pub, nil) as Data?
        else { throw ApproverRefusal("enclave_public_key_unavailable") }
        publicKeySPKI = try P256Keys.spki(fromX963: ext)
        kid = P256Keys.kid(spki: publicKeySPKI)
    }

    static func baseQuery(tag: Data) -> [String: Any] {
        [kSecClass as String: kSecClassKey,
         kSecAttrApplicationTag as String: tag,
         kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
         kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave]
    }

    /// Load the enclave key stored under `tag`, or create one if absent (`create: true`).
    public static func loadOrCreate(tag: String = "sa2a.approver.p256.v1", create: Bool = true) throws -> SecureEnclaveSigner {
        let tagData = Data(tag.utf8)
        var q = baseQuery(tag: tagData)
        q[kSecReturnRef as String] = true
        var item: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &item)
        if st == errSecSuccess, let item { return try SecureEnclaveSigner(privateKey: item as! SecKey, tag: tagData) }
        guard st == errSecItemNotFound, create else { throw ApproverRefusal("enclave_lookup_failed:\(st)") }
        var err: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &err)
        else { throw ApproverRefusal("enclave_access_control_failed") }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tagData,
                kSecAttrAccessControl as String: ac,
            ],
        ]
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw ApproverRefusal("enclave_keygen_failed:\(err.map { String(describing: $0.takeRetainedValue()) } ?? "?")")
        }
        return try SecureEnclaveSigner(privateKey: key, tag: tagData)
    }

    public func sign(message: Data, reason: String) throws -> Data {
        // Re-fetch the key with an LAContext whose localizedReason is the rendered summary,
        // so the biometric prompt shows what is being signed.
        let ctx = LAContext()
        ctx.localizedReason = reason
        var q = Self.baseQuery(tag: tag)
        q[kSecReturnRef as String] = true
        q[kSecUseAuthenticationContext as String] = ctx
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let item else {
            throw ApproverRefusal("enclave_key_unavailable")
        }
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(item as! SecKey, .ecdsaSignatureMessageX962SHA256,
                                              message as CFData, &err) as Data?
        else { throw ApproverRefusal("enclave_sign_failed:\(err.map { String(describing: $0.takeRetainedValue()) } ?? "?")") }
        return sig
    }
}
#endif
