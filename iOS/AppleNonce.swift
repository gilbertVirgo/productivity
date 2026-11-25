import Foundation
import CryptoKit

/// Sign in with Apple nonce: Apple gets the SHA-256, Supabase gets the raw value and checks they match.
enum AppleNonce {
    static func random() -> String { (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
    static func sha256(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}
