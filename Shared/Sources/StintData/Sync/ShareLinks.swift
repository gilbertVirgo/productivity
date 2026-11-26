import Foundation
import Supabase

/// One friend's link to the share page (spec §6.10). `friendLabel` is for the owner only; the page never sees it.
public struct ShareLinkRow: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let token: String
    public let friendLabel: String
    public let createdAt: Date

    public init(id: UUID, token: String, friendLabel: String, createdAt: Date) {
        self.id = id; self.token = token; self.friendLabel = friendLabel; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, token, friendLabel = "friend_label", createdAt = "created_at" }

    /// The page address for this link; nil when the app has no share page configured.
    public func url(base: String) -> URL? {
        base.isEmpty ? nil : URL(string: base + "?t=" + token) // tokens are base64url: no escaping needed
    }
}

/// No `updated_at`: links aren't synced, and a client stamp can land behind the server's (reject_stale would skip the write).
private struct Revocation: Encodable {
    let revokedAt: Date
    enum CodingKeys: String, CodingKey { case revokedAt = "revoked_at" }
}

private struct NewLink: Encodable {
    let friendLabel: String
    enum CodingKeys: String, CodingKey { case friendLabel = "friend_label" }
}

extension SyncEngine {
    static let shareLinkColumns = "id, token, friend_label, created_at"

    /// Active links, oldest first. Revoked rows stay on the server so a revoked token never comes back to life.
    public func shareLinks() async throws -> [ShareLinkRow] {
        try await client.from("share_link").select(Self.shareLinkColumns)
            .is("revoked_at", value: nil).order("created_at").execute().value
    }

    /// The server mints the token (32 random bytes, base64url).
    public func createShareLink(label: String) async throws -> ShareLinkRow {
        try await client.from("share_link").insert(NewLink(friendLabel: label), returning: .representation)
            .select(Self.shareLinkColumns).single().execute().value
    }

    public func revokeShareLink(id: UUID) async throws {
        try await client.from("share_link").update(Revocation(revokedAt: .now))
            .eq("id", value: id).execute()
    }
}
