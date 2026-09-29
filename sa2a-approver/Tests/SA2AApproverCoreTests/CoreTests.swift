import CryptoKit
import Foundation
import XCTest

@testable import SA2AApproverCore

/// Chicago-style: real collaborators (CryptoKit keys, real parser), state assertions only.
final class CoreTests: XCTestCase {
    // MARK: helpers

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let effectJSON =
        #"{"capability":"deploy.release","inputs":{"env":"prod","replicas":3},"target":"svc/payments"}"#

    static func effectBytes(_ s: String = effectJSON) -> Data { Data(s.utf8) }

    static func fields(kid: String, effect: Data = effectBytes(), notBefore: Int64 = 1_800_000_000 - 10,
                       expires: Int64 = 1_800_000_000 + 200) -> ApprovalFields {
        ApprovalFields(
            v: 1, alg: "ES256", kid: kid, effectDigest: WYSIWYS.effectDigest(effect),
            principal: "human:alice", policyEpoch: 7, revocationEpoch: 3, generation: 11,
            nonce: "n-0001", notBefore: notBefore, expires: expires, audience: "actuator:prod-1")
    }

    static func signer() throws -> SoftwareP256Signer {
        try SoftwareP256Signer(privateKey: P256.Signing.PrivateKey(), devFlag: true)
    }

    func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let e as ApproverRefusal { return e.code } catch { return "other:\(error)" }
    }

    // MARK: JCS / strict JSON

    func testJCSSortsKeysAndRoundTrips() throws {
        let v = try StrictJSON.parse(Data(#"{"b":1,"a":[true,null,"x"]}"#.utf8))
        XCTAssertEqual(String(decoding: JCS.serialize(v), as: UTF8.self), #"{"a":[true,null,"x"],"b":1}"#)
    }

    func testRefusesFloatsDuplicatesNoncanonicalAndOversize() {
        XCTAssertEqual(refusal { _ = try StrictJSON.parseCanonical(Data(#"{"a":1.5}"#.utf8)) }, "float_refused")
        XCTAssertEqual(refusal { _ = try StrictJSON.parseCanonical(Data(#"{"a":1e2}"#.utf8)) }, "float_refused")
        XCTAssertEqual(refusal { _ = try StrictJSON.parseCanonical(Data(#"{"a":1,"a":2}"#.utf8)) }, "duplicate_key")
        XCTAssertEqual(refusal { _ = try StrictJSON.parseCanonical(Data(#"{"b":1,"a":2}"#.utf8)) }, "not_canonical")
        XCTAssertEqual(refusal { _ = try StrictJSON.parseCanonical(Data(#"{"a": 1}"#.utf8)) }, "not_canonical")
        XCTAssertEqual(refusal { _ = try StrictJSON.parse(Data(repeating: 0x20, count: 70_000)) }, "oversize")
        XCTAssertEqual(refusal { _ = try StrictJSON.parse(Data(#"{"a":9223372036854775808}"#.utf8)) }, "integer_out_of_range")
    }

    // MARK: message + WYSIWYS

    func testSignedBytesParseBackToSameFields() throws {
        let f = Self.fields(kid: "kid-x")
        let bytes = f.signedBytes()
        XCTAssertTrue(bytes.starts(with: Data("SA2A-C2-APPROVAL-v1".utf8) + Data([0])))
        XCTAssertEqual(try ApprovalMessage.parse(bytes), f)
    }

    func testParseRefusesWrongDomainExtraAndMissingFields() throws {
        let f = Self.fields(kid: "k")
        var wrong = f.signedBytes(); wrong[0] = 0x58
        XCTAssertEqual(refusal { _ = try ApprovalMessage.parse(wrong) }, "bad_domain")
        let prefix = Data("SA2A-C2-APPROVAL-v1".utf8) + Data([0])
        let json = String(decoding: f.signedBytes().dropFirst(prefix.count), as: UTF8.self)
        let extra = json.replacingOccurrences(of: #"{"alg""#, with: #"{"alg":"ES256","zzz":1,"alg2""#)
        _ = extra
        var obj = try StrictJSON.parse(Data(json.utf8))
        guard case .object(var d) = obj else { return XCTFail() }
        d["extra"] = .int(1)
        obj = .object(d)
        XCTAssertEqual(refusal { _ = try ApprovalMessage.parse(prefix + JCS.serialize(obj)) }, "unexpected_field")
        d["extra"] = nil; d["nonce"] = nil
        XCTAssertEqual(refusal { _ = try ApprovalMessage.parse(prefix + JCS.serialize(.object(d))) }, "missing_field:nonce")
        d["nonce"] = .int(5)
        XCTAssertEqual(refusal { _ = try ApprovalMessage.parse(prefix + JCS.serialize(.object(d))) }, "bad_type:nonce")
    }

    /// ERR7-I-1: display-affecting bytes mutated while the digest stays -> refuse (digest recomputed locally).
    func testMutatedEffectBytesRefusedByLocalDigest() throws {
        let s = try Self.signer()
        let f = Self.fields(kid: s.kid)
        let tampered = Self.effectBytes(Self.effectJSON.replacingOccurrences(of: "svc/payments", with: "svc/payrolls"))
        XCTAssertEqual(
            refusal { _ = try Approver.approve(messageBytes: f.signedBytes(), effectBytes: tampered, signer: s, now: Self.now) },
            "effect_digest_mismatch")
    }

    func testSummaryDerivedFromBytesOnlyAndSanitised() throws {
        let effect = Self.effectBytes(#"{"capability":"pay‮evil","target":"svc/payments"}"#)
        let f = Self.fields(kid: "k", effect: effect)
        let summary = WYSIWYS.summary(fields: f, effect: try StrictJSON.parseCanonical(effect))
        XCTAssertTrue(summary.contains("svc/payments"))
        XCTAssertTrue(summary.contains("actuator:prod-1"))
        XCTAssertTrue(summary.contains(f.effectDigest))
        XCTAssertFalse(summary.contains("\u{202E}"), "bidi override must be escaped, not rendered")
        XCTAssertTrue(summary.contains("\\u{202E}"))
    }

    // MARK: signing

    func testSoftwareSignerRefusedWithoutDevFlag() {
        XCTAssertEqual(
            refusal { _ = try SoftwareP256Signer(privateKey: P256.Signing.PrivateKey(), devFlag: false) },
            "software_signer_refused")
    }

    func testKidAndSPKIShape() throws {
        let s = try Self.signer()
        XCTAssertEqual(s.publicKeySPKI.count, 91)
        let expected = Base64URL.encode(Data(SHA256.hash(data: s.publicKeySPKI).prefix(16)))
        XCTAssertEqual(s.kid, expected)
        XCTAssertEqual(s.kid.count, 22)
        XCTAssertEqual(try P256Keys.x963(fromSPKI: s.publicKeySPKI).count, 65)
        XCTAssertEqual(refusal { _ = try P256Keys.x963(fromSPKI: Data([1, 2, 3])) }, "bad_spki")
    }

    func testApproveProducesVerifiableStrictDER() throws {
        let s = try Self.signer()
        let f = Self.fields(kid: s.kid)
        let r = try Approver.approve(messageBytes: f.signedBytes(), effectBytes: Self.effectBytes(), signer: s, now: Self.now)
        XCTAssertNotNil(DERSignature.parseStrict(r.signature))
        XCTAssertTrue(P256Verifier.verify(spki: s.publicKeySPKI, message: f.signedBytes(), derSignature: r.signature))
        XCTAssertEqual(s.lastReason, r.summary, "the biometric prompt reason must be the rendered summary")
        // negatives
        var flipped = r.signature; flipped[flipped.count - 1] ^= 1
        XCTAssertFalse(P256Verifier.verify(spki: s.publicKeySPKI, message: f.signedBytes(), derSignature: flipped))
        var m2 = f.signedBytes(); m2[m2.count - 3] ^= 1
        XCTAssertFalse(P256Verifier.verify(spki: s.publicKeySPKI, message: m2, derSignature: r.signature))
        let other = try Self.signer()
        XCTAssertFalse(P256Verifier.verify(spki: other.publicKeySPKI, message: f.signedBytes(), derSignature: r.signature))
        XCTAssertFalse(P256Verifier.verify(spki: s.publicKeySPKI, message: f.signedBytes(), derSignature: r.signature + Data([0])))
    }

    func testApproveRefusals() throws {
        let s = try Self.signer()
        let e = Self.effectBytes()
        func run(_ f: ApprovalFields, now: Date = Self.now) -> String? {
            refusal { _ = try Approver.approve(messageBytes: f.signedBytes(), effectBytes: e, signer: s, now: now) }
        }
        XCTAssertEqual(run(Self.fields(kid: "someone-else")), "kid_mismatch")
        var badAlg = Self.fields(kid: s.kid); badAlg.alg = "EdDSA"
        XCTAssertEqual(run(badAlg), "alg_unsupported")
        XCTAssertEqual(run(Self.fields(kid: s.kid, notBefore: 1_800_000_000, expires: 1_800_000_301)), "ttl_exceeds_max")
        XCTAssertNil(run(Self.fields(kid: s.kid, notBefore: 1_800_000_000, expires: 1_800_000_300)))
        XCTAssertEqual(run(Self.fields(kid: s.kid), now: Date(timeIntervalSince1970: 1_800_000_500)), "expired")
        XCTAssertEqual(run(Self.fields(kid: s.kid), now: Date(timeIntervalSince1970: 1_700_000_000)), "not_yet_valid")
        XCTAssertEqual(run(Self.fields(kid: s.kid, notBefore: 5, expires: 5)), "ttl_invalid")
    }

    // MARK: cross-runtime fixtures

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testSwiftVerifiesElixirSignedFixture() throws {
        let dir = Self.repoRoot().appendingPathComponent("sa2a-approver/Tests/SA2AApproverCoreTests/Fixtures/elixir")
        let msg = try Data(contentsOf: dir.appendingPathComponent("message.bin"))
        let sig = try Data(contentsOf: dir.appendingPathComponent("signature.der"))
        let spki = try Data(contentsOf: dir.appendingPathComponent("spki.der"))
        let kid = try String(contentsOf: dir.appendingPathComponent("kid.txt"), encoding: .utf8)
        XCTAssertEqual(kid, P256Keys.kid(spki: spki), "Elixir and Swift derive the same kid")
        XCTAssertNotNil(DERSignature.parseStrict(sig))
        XCTAssertTrue(P256Verifier.verify(spki: spki, message: msg, derSignature: sig))
        XCTAssertEqual(try ApprovalMessage.parse(msg).kid, kid)
        var bad = msg; bad[25] ^= 1
        XCTAssertFalse(P256Verifier.verify(spki: spki, message: bad, derSignature: sig))
        var badSig = sig; badSig[10] ^= 1
        XCTAssertFalse(P256Verifier.verify(spki: spki, message: msg, derSignature: badSig))
    }

    func testCommittedSwiftFixturesVerifyInSwiftToo() throws {
        let dir = Self.repoRoot().appendingPathComponent("test/support/approver_fixtures/case1")
        let msg = try Data(contentsOf: dir.appendingPathComponent("message.bin"))
        let sig = try Data(contentsOf: dir.appendingPathComponent("signature.der"))
        let spki = try Data(contentsOf: dir.appendingPathComponent("spki.der"))
        XCTAssertTrue(P256Verifier.verify(spki: spki, message: msg, derSignature: sig))
    }
}
