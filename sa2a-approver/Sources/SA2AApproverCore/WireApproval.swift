import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// UNVERIFIED: written without a Swift or Elixir toolchain; not compiled, not run.

/// The authority service's `"approve"` wire op: one `<<len::32 big-endian, json>>` frame per
/// connection over a unix socket, one frame back. Request:
/// `{"op":"approve","approver":id,"effect_digest":d,"generation":n,"approval":{"envelope":{...},"message":b64url}}`.
/// The service only deposits the approval; the issuer re-verifies it at `issue` time, so this
/// client grants nothing by submitting. Mutual TLS is not implemented here (unix socket only).
public enum WireApproval {
    /// The Sa2aCrypto SignatureEnvelope (classical profile) for a signed approval message.
    public static func envelope(fields f: ApprovalFields, signatureDER: Data, messageBytes: Data) -> JSONValue {
        .object([
            "v": .int(f.v), "alg": .string(f.alg), "kid": .string(f.kid), "profile": .string("classical"),
            "signed_bytes_digest": .string(WYSIWYS.effectDigest(messageBytes)),
            "signature": .string(Base64URL.encode(signatureDER)),
            "nonce": .string(f.nonce), "not_before": .int(f.notBefore), "expires": .int(f.expires),
            "audience": .string(f.audience),
        ])
    }

    /// The request body (unframed JSON) for one signed approval.
    public static func requestBody(approver: String, result: ApprovalResult, messageBytes: Data) throws -> Data {
        guard !approver.isEmpty, approver.utf8.count <= 512 else { throw ApproverRefusal("bad_approver_id") }
        let f = result.fields
        guard f.generation >= 0 else { throw ApproverRefusal("bad_generation") }
        return JCS.serialize(.object([
            "op": .string("approve"),
            "approver": .string(approver),
            "effect_digest": .string(f.effectDigest),
            "generation": .int(f.generation),
            "approval": .object([
                "envelope": envelope(fields: f, signatureDER: result.signature, messageBytes: messageBytes),
                "message": .string(Base64URL.encode(messageBytes)),
            ]),
        ]))
    }

    public static func frame(_ body: Data) -> Data {
        var n = UInt32(body.count).bigEndian
        return Data(bytes: &n, count: 4) + body
    }

    /// Interpret the service's reply body: `{"ok":true}` -> nil, a refusal -> its code.
    /// Anything else throws `bad_reply`.
    public static func refusalCode(inReply body: Data) throws -> String? {
        guard case .object(let d) = try StrictJSON.parse(body), case .bool(let ok)? = d["ok"] else {
            throw ApproverRefusal("bad_reply")
        }
        if ok { return nil }
        guard case .string(let code)? = d["refusal"] else { throw ApproverRefusal("bad_reply") }
        return code
    }
}

/// Blocking one-frame request/response over a unix domain socket.
public enum UnixFrameClient {
    public static let maxReply = 1_048_576

    public static func call(path: String, body: Data, timeoutSeconds: Int = 5) throws -> Data {
        #if canImport(Darwin)
        let stream = Int32(SOCK_STREAM)
        #else
        let stream = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_UNIX, stream, 0)
        guard fd >= 0 else { throw ApproverRefusal("socket_failed") }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= cap else { throw ApproverRefusal("socket_path_too_long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw ApproverRefusal("connect_failed") }

        let out = [UInt8](WireApproval.frame(body))
        var sent = 0
        while sent < out.count {
            let n = out[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { throw ApproverRefusal("send_failed") }
            sent += n
        }
        let head = try readExactly(fd, 4)
        let len = head.reduce(0) { ($0 << 8) | Int($1) }
        guard len <= maxReply else { throw ApproverRefusal("reply_too_large") }
        return Data(try readExactly(fd, len))
    }

    static func readExactly(_ fd: Int32, _ n: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf[got...].withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard r > 0 else { throw ApproverRefusal("recv_failed") }
            got += r
        }
        return buf
    }
}
