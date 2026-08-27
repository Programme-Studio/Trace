import CryptoKit
import Foundation
import Security

/// Proof Key for Code Exchange — lets a desktop app do OAuth without shipping a client secret.
struct PKCE {
    let verifier: String
    let challenge: String

    init() {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let v = Data(bytes).base64URLEncodedString()
        verifier = v
        challenge = Data(SHA256.hash(data: Data(v.utf8))).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
