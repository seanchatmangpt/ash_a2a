import CryptoKit
import Foundation

/// The twelve signed fields of RFC-SA2A-007 E-E. Integer typing (v, epochs, generation,
/// not_before/expires as unix seconds) is this approver's reading of the contract; every other
/// field is a string.
public struct ApprovalFields: Equatable {
    public var v: Int64
    public var alg: String
    public var kid: String
    public var effectDigest: String
    public var principal: String
    public var policyEpoch: Int64
    public var revocationEpoch: Int64
    public var generation: Int64
    public var nonce: String
    public var notBefore: Int64
    public var expires: Int64
    public var audience: String

    public init(v: Int64, alg: String, kid: String, effectDigest: String, principal: String,
                policyEpoch: Int64, revocationEpoch: Int64, generation: Int64, nonce: String,
                notBefore: Int64, expires: Int64, audience: String) {
        self.v = v; self.alg = alg; self.kid = kid; self.effectDigest = effectDigest
        self.principal = principal; self.policyEpoch = policyEpoch; self.revocationEpoch = revocationEpoch
        self.generation = generation; self.nonce = nonce; self.notBefore = notBefore
        self.expires = expires; self.audience = audience
    }

    var json: JSONValue {
        .object([
            "v": .int(v), "alg": .string(alg), "kid": .string(kid), "effect_digest": .string(effectDigest),
            "principal": .string(principal), "policy_epoch": .int(policyEpoch),
            "revocation_epoch": .int(revocationEpoch), "generation": .int(generation),
            "nonce": .string(nonce), "not_before": .int(notBefore), "expires": .int(expires),
            "audience": .string(audience),
        ])
    }

    /// `"SA2A-C2-APPROVAL-v1" || 0x00 || JCS({...})`
    public func signedBytes() -> Data { ApprovalMessage.domainPrefix + JCS.serialize(json) }
}

public enum ApprovalMessage {
    public static let domain = "SA2A-C2-APPROVAL-v1"
    public static var domainPrefix: Data { Data(domain.utf8) + Data([0]) }

    static let intFields = ["v", "policy_epoch", "revocation_epoch", "generation", "not_before", "expires"]
    static let strFields = ["alg", "kid", "effect_digest", "principal", "nonce", "audience"]

    /// Parse the canonical signed bytes. Refuses anything it cannot fully understand.
    public static func parse(_ bytes: Data) throws -> ApprovalFields {
        let prefix = domainPrefix
        guard bytes.count > prefix.count, bytes.prefix(prefix.count) == prefix else { throw ApproverRefusal("bad_domain") }
        let body = Data(bytes.dropFirst(prefix.count))
        guard case .object(let d) = try StrictJSON.parseCanonical(body) else { throw ApproverRefusal("not_object") }
        let allowed = Set(intFields + strFields)
        for k in d.keys.sorted() where !allowed.contains(k) { throw ApproverRefusal("unexpected_field") }
        var ints = [String: Int64](), strs = [String: String]()
        for k in intFields {
            guard let v = d[k] else { throw ApproverRefusal("missing_field:\(k)") }
            guard case .int(let n) = v else { throw ApproverRefusal("bad_type:\(k)") }
            ints[k] = n
        }
        for k in strFields {
            guard let v = d[k] else { throw ApproverRefusal("missing_field:\(k)") }
            guard case .string(let s) = v, !s.isEmpty, s.utf8.count <= 512 else { throw ApproverRefusal("bad_type:\(k)") }
            strs[k] = s
        }
        guard isValidDigest(strs["effect_digest"]!) else { throw ApproverRefusal("bad_effect_digest") }
        return ApprovalFields(
            v: ints["v"]!, alg: strs["alg"]!, kid: strs["kid"]!, effectDigest: strs["effect_digest"]!,
            principal: strs["principal"]!, policyEpoch: ints["policy_epoch"]!,
            revocationEpoch: ints["revocation_epoch"]!, generation: ints["generation"]!,
            nonce: strs["nonce"]!, notBefore: ints["not_before"]!, expires: ints["expires"]!,
            audience: strs["audience"]!)
    }

    static func isValidDigest(_ s: String) -> Bool {
        guard s.hasPrefix("sha256:") else { return false }
        let h = s.dropFirst(7)
        return h.utf8.count == 64 && h.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

/// What-you-see-is-what-you-sign: digest recomputed locally, summary derived only from bytes.
public enum WYSIWYS {
    public static func effectDigest(_ effectBytes: Data) -> String {
        "sha256:" + SHA256.hash(data: effectBytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Recompute the digest from the canonical effect bytes; refuse on mismatch or non-canonical bytes.
    public static func verifyEffect(fields: ApprovalFields, effectBytes: Data) throws -> JSONValue {
        let parsed = try StrictJSON.parseCanonical(effectBytes)
        guard effectDigest(effectBytes) == fields.effectDigest else { throw ApproverRefusal("effect_digest_mismatch") }
        return parsed
    }

    /// Human summary from the signed fields and parsed effect bytes only (no other inputs exist).
    public static func summary(fields: ApprovalFields, effect: JSONValue) -> String {
        var lines = [
            "APPROVE EFFECT",
            "principal: \(esc(fields.principal))",
            "audience: \(esc(fields.audience))",
            "valid: \(fields.notBefore) .. \(fields.expires) (unix s)",
            "policy_epoch: \(fields.policyEpoch)  revocation_epoch: \(fields.revocationEpoch)  generation: \(fields.generation)",
            "nonce: \(esc(fields.nonce))",
            "effect_digest: \(fields.effectDigest)",
            "effect:",
        ]
        render(effect, indent: 1, into: &lines)
        return lines.joined(separator: "\n")
    }

    static func render(_ v: JSONValue, indent: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: indent)
        switch v {
        case .object(let d):
            for k in d.keys.sorted() {
                switch d[k]! {
                case .object, .array:
                    lines.append("\(pad)\(esc(k)):"); render(d[k]!, indent: indent + 1, into: &lines)
                default: lines.append("\(pad)\(esc(k)): \(scalar(d[k]!))")
                }
            }
        case .array(let a):
            for e in a {
                switch e {
                case .object, .array: lines.append("\(pad)-"); render(e, indent: indent + 1, into: &lines)
                default: lines.append("\(pad)- \(scalar(e))")
                }
            }
        default: lines.append("\(pad)\(scalar(v))")
        }
    }

    static func scalar(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return esc(s)
        case .int(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        default: return ""
        }
    }

    /// Escape controls, bidi and invisible format characters so the display cannot be visually spoofed.
    static func esc(_ s: String) -> String {
        var out = ""
        for sc in s.unicodeScalars {
            let v = sc.value
            let bad = v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || (0x200B...0x200F).contains(v)
                || (0x202A...0x202E).contains(v) || (0x2060...0x2069).contains(v) || v == 0xFEFF
            out += bad ? "\\u{\(String(v, radix: 16, uppercase: true))}" : String(Character(sc))
        }
        return out
    }
}

public struct ApprovalResult {
    public let signature: Data
    public let summary: String
    public let fields: ApprovalFields
}

public enum Approver {
    public static let maxTTLSeconds: Int64 = 300
    public static let skewSeconds: Int64 = 5

    /// Validate message + effect, render the summary, and ask `signer` (biometric gate) to sign.
    public static func approve(messageBytes: Data, effectBytes: Data, signer: ApprovalSigner,
                               now: Date = Date(), maxTTL: Int64 = Approver.maxTTLSeconds) throws -> ApprovalResult {
        let f = try ApprovalMessage.parse(messageBytes)
        guard f.v == 1 else { throw ApproverRefusal("version_unsupported") }
        guard f.alg == signer.alg else { throw ApproverRefusal("alg_unsupported") }
        guard f.kid == signer.kid else { throw ApproverRefusal("kid_mismatch") }
        guard f.expires > f.notBefore else { throw ApproverRefusal("ttl_invalid") }
        guard f.expires - f.notBefore <= maxTTL else { throw ApproverRefusal("ttl_exceeds_max") }
        let t = Int64(now.timeIntervalSince1970)
        guard t >= f.notBefore - skewSeconds else { throw ApproverRefusal("not_yet_valid") }
        guard t < f.expires + skewSeconds else { throw ApproverRefusal("expired") }
        let effect = try WYSIWYS.verifyEffect(fields: f, effectBytes: effectBytes)
        let summary = WYSIWYS.summary(fields: f, effect: effect)
        let sig = try signer.sign(message: messageBytes, reason: summary)
        return ApprovalResult(signature: sig, summary: summary, fields: f)
    }
}
