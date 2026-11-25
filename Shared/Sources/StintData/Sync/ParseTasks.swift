import Foundation
import Supabase
import Core

private struct ParseRequest: Encodable {
    struct P: Encodable { let id: UUID; let name: String }
    let transcript: String
    let projects: [P]
}
private struct ParseResponse: Decodable { let tasks: [ParsedTask] }

extension SyncEngine {
    /// Calls the `parse-tasks` edge function with the signed-in user's token. Throws on any non-2xx (503 = no AI key yet).
    public func parseTasks(transcript: String, projects: [Project]) async throws -> [ParsedTask] {
        let body = ParseRequest(transcript: transcript, projects: projects.map { .init(id: $0.id, name: $0.name) })
        let r: ParseResponse = try await client.functions.invoke("parse-tasks", options: FunctionInvokeOptions(body: body),
                                                                 decoder: JSONDecoder())
        return r.tasks
    }
}
