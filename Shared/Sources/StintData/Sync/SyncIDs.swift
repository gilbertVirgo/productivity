import Foundation
import CryptoKit

public enum SyncIDs {
    /// Deterministic UUIDv5-style id so both devices derive identical child-row ids.
    public static func derived(_ sessionID: UUID, _ kind: String, _ index: Int) -> UUID {
        var b = Array(Insecure.SHA1.hash(data: Data("\(sessionID.uuidString)/\(kind)/\(index)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
