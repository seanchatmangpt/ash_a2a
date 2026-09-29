#if canImport(SwiftUI)
import Foundation
import SA2AApproverCore
import SwiftUI

/// Shared model: everything shown comes from the canonical bytes via SA2AApproverCore.
public final class ApproverModel: ObservableObject {
    @Published public var messageBytes: Data?
    @Published public var effectBytes: Data?
    @Published public var summary: String = "Load a message and its canonical effect bytes."
    @Published public var status: String = ""
    @Published public var signatureBase64: String = ""
    private var signer: ApprovalSigner?

    public init() {}

    public func load(message: Data, effect: Data) {
        messageBytes = message; effectBytes = effect; signatureBase64 = ""
        do {
            let f = try ApprovalMessage.parse(message)
            let e = try WYSIWYS.verifyEffect(fields: f, effectBytes: effect)
            summary = WYSIWYS.summary(fields: f, effect: e)
            status = "Digest recomputed locally: OK"
        } catch {
            summary = "REFUSED: cannot render (\(error)). Nothing can be signed."
            status = "refused"
        }
    }

    public func approve() {
        guard let m = messageBytes, let e = effectBytes else { status = "nothing loaded"; return }
        do {
            if signer == nil {
                #if canImport(LocalAuthentication)
                signer = SoftwareP256Signer.devFlagFromEnvironment()
                    ? try SoftwareP256Signer() : try SecureEnclaveSigner.loadOrCreate()
                #else
                signer = try SoftwareP256Signer()
                #endif
            }
            let r = try Approver.approve(messageBytes: m, effectBytes: e, signer: signer!)
            signatureBase64 = r.signature.base64EncodedString()
            status = "Signed (kid \(signer!.kid))"
        } catch { status = "REFUSED: \(error)" }
    }
}

public struct ApproverView: View {
    @StateObject private var model = ApproverModel()
    @State private var messageB64 = ""
    @State private var effectB64 = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SA2A Approver").font(.title2)
            TextField("message (base64 of signed bytes)", text: $messageB64)
            TextField("effect (base64 of canonical effect bytes)", text: $effectB64)
            Button("Render") {
                if let m = Data(base64Encoded: messageB64), let e = Data(base64Encoded: effectB64) { model.load(message: m, effect: e) }
                else { model.status = "invalid base64" }
            }
            ScrollView { Text(model.summary).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            Button("Approve with Touch ID / Face ID") { model.approve() }
            Text(model.status)
            if !model.signatureBase64.isEmpty { Text(model.signatureBase64).font(.caption).textSelection(.enabled) }
        }
        .padding()
    }
}
#endif
