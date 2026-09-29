import CryptoKit
import Foundation
import SA2AApproverCore

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

func opts(_ args: [String]) -> [String: String] {
    var o = [String: String](), i = 0
    while i < args.count {
        guard args[i].hasPrefix("--"), i + 1 < args.count else { fail("bad arguments near \(args[i])") }
        o[String(args[i].dropFirst(2))] = args[i + 1]; i += 2
    }
    return o
}

func need(_ o: [String: String], _ k: String) -> String {
    guard let v = o[k] else { fail("missing --\(k)") }
    return v
}

func makeSigner(_ o: [String: String]) throws -> ApprovalSigner {
    switch need(o, "key") {
    case "software":
        guard let path = o["key-file"] else { fail("--key software requires --key-file (dev only; also set SA2A_APPROVER_DEV=1)") }
        let url = URL(fileURLWithPath: path)
        let key: P256.Signing.PrivateKey
        if let raw = try? Data(contentsOf: url) { key = try P256.Signing.PrivateKey(rawRepresentation: raw) }
        else { key = P256.Signing.PrivateKey(); try key.rawRepresentation.write(to: url) }
        return try SoftwareP256Signer(privateKey: key)
    case "enclave":
        #if canImport(LocalAuthentication)
        return try SecureEnclaveSigner.loadOrCreate()
        #else
        fail("enclave signer unavailable on this platform")
        #endif
    default: fail("--key must be software|enclave")
    }
}

func writeFixtures(dir: String) throws {
    let base = URL(fileURLWithPath: dir)
    let effects = [
        #"{"capability":"deploy.release","inputs":{"env":"prod","replicas":3},"target":"svc/payments"}"#,
        #"{"capability":"secret.rotate","inputs":{"keys":["a","b"],"reason":"quarterly"},"target":"vault/prod"}"#,
        #"{"capability":"repo.merge","inputs":{"pr":1234,"squash":true},"target":"org/repo"}"#,
    ]
    var names = [String]()
    for (idx, eff) in effects.enumerated() {
        let name = "case\(idx + 1)"; names.append(name)
        let effect = Data(eff.utf8)
        let signer = try SoftwareP256Signer()
        let f = ApprovalFields(
            v: 1, alg: "ES256", kid: signer.kid, effectDigest: WYSIWYS.effectDigest(effect),
            principal: "human:alice", policyEpoch: 7, revocationEpoch: 3, generation: Int64(idx + 1),
            nonce: "fixture-nonce-\(idx + 1)", notBefore: 1_800_000_000, expires: 1_800_000_300,
            audience: "actuator:prod-1")
        let r = try Approver.approve(messageBytes: f.signedBytes(), effectBytes: effect, signer: signer,
                                     now: Date(timeIntervalSince1970: 1_800_000_001))
        let d = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try effect.write(to: d.appendingPathComponent("effect.json"))
        try f.signedBytes().write(to: d.appendingPathComponent("message.bin"))
        try r.signature.write(to: d.appendingPathComponent("signature.der"))
        try signer.publicKeySPKI.write(to: d.appendingPathComponent("spki.der"))
        try Data(signer.kid.utf8).write(to: d.appendingPathComponent("kid.txt"))
        try Data(r.summary.utf8).write(to: d.appendingPathComponent("summary.txt"))
    }
    let manifest = "{\"cases\":[" + names.map { "\"\($0)\"" }.joined(separator: ",") + "],\"producer\":\"sa2a-approver SoftwareP256Signer\"}\n"
    try Data(manifest.utf8).write(to: base.appendingPathComponent("manifest.json"))
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail("usage: sa2a-approver sign|pubkey|fixtures ...") }
do {
    let o = opts(Array(args.dropFirst()))
    switch cmd {
    case "sign":
        let msg = try Data(contentsOf: URL(fileURLWithPath: need(o, "message")))
        let eff = try Data(contentsOf: URL(fileURLWithPath: need(o, "effect")))
        let r = try Approver.approve(messageBytes: msg, effectBytes: eff, signer: try makeSigner(o))
        try r.signature.write(to: URL(fileURLWithPath: need(o, "out")))
        print(r.summary)
    case "pubkey":
        let s = try makeSigner(o)
        try s.publicKeySPKI.write(to: URL(fileURLWithPath: need(o, "out")))
        print("kid \(s.kid)")
    case "fixtures":
        try writeFixtures(dir: need(o, "out"))
    default: fail("unknown command \(cmd)")
    }
} catch { fail("\(error)") }
