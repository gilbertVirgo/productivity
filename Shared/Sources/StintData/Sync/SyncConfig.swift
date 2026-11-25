import Foundation
import Supabase

public enum SyncConfig {
    /// The app's Supabase client, from Info.plist keys `StintSupabaseURL` / `StintSupabaseAnonKey`.
    /// nil when either is missing, empty (Release until production exists) or an unexpanded `$(…)`.
    public static func client(info: [String: Any]?) -> SupabaseClient? {
        func value(_ k: String) -> String? { (info?[k] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } }
        guard let url = value("StintSupabaseURL").flatMap(URL.init(string:)), let key = value("StintSupabaseAnonKey") else { return nil }
        return SupabaseClient(supabaseURL: url, supabaseKey: key,
                              options: .init(db: .init(encoder: SyncCoding.encoder, decoder: SyncCoding.decoder),
                                             auth: .init(emitLocalSessionAsInitialSession: true)))
    }
}
