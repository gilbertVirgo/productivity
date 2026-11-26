import Foundation
import Supabase
import Core

extension SyncEngine {
    /// Asks `push-activity` to push this change to the user's iPhones. Throws on any non-2xx (503 = no APNs key yet).
    public func pushActivity(_ push: LivePush) async throws {
        try await client.functions.invoke("push-activity", options: FunctionInvokeOptions(body: push))
    }

    /// Upserts this phone's push tokens. `updated_at` must be now: the server skips older writes.
    public func saveDevice(_ row: DeviceRow) async throws {
        try await client.from("device").upsert([row], onConflict: "id", returning: .minimal).execute()
    }

    /// Removes this phone's device row so a signed-out phone stops receiving the account's activities.
    public func deleteDevice(id: UUID) async throws {
        try await client.from("device").delete().eq("id", value: id).execute()
    }
}
