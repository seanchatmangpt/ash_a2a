import CryptoKit
import Foundation
import XCTest

@testable import SA2AApproverCore

// UNVERIFIED: written without a Swift toolchain; not compiled, not run.
// The server below is a real unix-socket peer speaking the listener's framing, but it is a
// stand-in: the Elixir `AuthorityService.Listener` is NOT started from Swift. Interop with the
// real listener is not tested by any test here (see docs/how-to/approve-over-the-wire.md).
final class WireApprovalTests: XCTestCase {
    /// One-shot server: accepts one connection, captures the request frame body, replies with `reply`.
    final class OneShotServer {
        let path: String
        private let lfd: Int32
        private let lock = NSLock()
        private var _body: Data?
        var body: Data? { lock.lock(); defer { lock.unlock() }; return _body }
        let done = DispatchSemaphore(value: 0)

        init(path: String, reply: Data) throws {
            self.path = path
            unlink(path)
            #if canImport(Darwin)
            let stream = Int32(SOCK_STREAM)
            #else
            let stream = Int32(SOCK_STREAM.rawValue)
            #endif
            lfd = socket(AF_UNIX, stream, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0, listen(lfd, 1) == 0 else { throw ApproverRefusal("test_listen_failed") }
            Thread.detachNewThread { [self] in
                let c = accept(lfd, nil, nil)
                if c >= 0 {
                    if let head = try? UnixFrameClient.readExactly(c, 4) {
                        let len = head.reduce(0) { ($0 << 8) | Int($1) }
                        if let b = try? UnixFrameClient.readExactly(c, len) {
                            lock.lock(); _body = Data(b); lock.unlock()
                        }
                    }
                    let out = [UInt8](WireApproval.frame(reply))
                    _ = out.withUnsafeBytes { send(c, $0.baseAddress, $0.count, 0) }
                    close(c)
                }
                done.signal()
            }
        }

        deinit { close(lfd); unlink(path) }
    }

    func signedResult() throws -> (ApprovalResult, Data, SoftwareP256Signer) {
        let s = try CoreTests.signer()
        let effect = CoreTests.effectBytes()
        let f = CoreTests.fields(kid: s.kid, effect: effect)
        let msg = f.signedBytes()
        let r = try Approver.approve(messageBytes: msg, effectBytes: effect, signer: s, now: CoreTests.now)
        return (r, msg, s)
    }

    func tmpSocket() -> String {
        // sun_path is short (104 on Darwin): keep the name small.
        "/tmp/wa-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    func testRequestBodyCarriesTheListenersApproveShape() throws {
        let (r, msg, s) = try signedResult()
        let body = try WireApproval.requestBody(approver: "alice", result: r, messageBytes: msg)
        guard case .object(let d) = try StrictJSON.parse(body) else { return XCTFail() }
        XCTAssertEqual(d["op"], .string("approve"))
        XCTAssertEqual(d["approver"], .string("alice"))
        XCTAssertEqual(d["effect_digest"], .string(r.fields.effectDigest))
        XCTAssertEqual(d["generation"], .int(r.fields.generation))
        guard case .object(let a)? = d["approval"], case .object(let env)? = a["envelope"] else { return XCTFail() }
        XCTAssertEqual(a["message"], .string(Base64URL.encode(msg)))
        XCTAssertEqual(Set(env.keys), ["v", "alg", "kid", "profile", "signed_bytes_digest", "signature",
                                       "nonce", "not_before", "expires", "audience"])
        XCTAssertEqual(env["profile"], .string("classical"))
        XCTAssertEqual(env["kid"], .string(s.kid))
        XCTAssertEqual(env["signed_bytes_digest"], .string(WYSIWYS.effectDigest(msg)))
        XCTAssertEqual(env["signature"], .string(Base64URL.encode(r.signature)))
    }

    func testSubmitsOneFrameOverUnixSocketAndReadsOk() throws {
        let (r, msg, _) = try signedResult()
        let server = try OneShotServer(path: tmpSocket(), reply: Data(#"{"ok":true}"#.utf8))
        let body = try WireApproval.requestBody(approver: "alice", result: r, messageBytes: msg)
        let reply = try UnixFrameClient.call(path: server.path, body: body)
        XCTAssertNil(try WireApproval.refusalCode(inReply: reply))
        _ = server.done.wait(timeout: .now() + 5)
        XCTAssertEqual(server.body, body)
    }

    func testRefusalFromServiceSurfacesItsCode() throws {
        let (r, msg, _) = try signedResult()
        let reply = Data(#"{"ok":false,"refusal":"duplicate_approval","detail":[]}"#.utf8)
        let server = try OneShotServer(path: tmpSocket(), reply: reply)
        let body = try WireApproval.requestBody(approver: "alice", result: r, messageBytes: msg)
        let got = try UnixFrameClient.call(path: server.path, body: body)
        XCTAssertEqual(try WireApproval.refusalCode(inReply: got), "duplicate_approval")
    }

    func testRefusesBadInputsAndMalformedReplies() throws {
        let (r, msg, _) = try signedResult()
        XCTAssertThrowsError(try WireApproval.requestBody(approver: "", result: r, messageBytes: msg))
        XCTAssertThrowsError(try WireApproval.refusalCode(inReply: Data("[]".utf8)))
        XCTAssertThrowsError(try WireApproval.refusalCode(inReply: Data(#"{"ok":false}"#.utf8)))
        XCTAssertThrowsError(try UnixFrameClient.call(path: "/nonexistent/wa.sock", body: Data("{}".utf8)))
    }
}
