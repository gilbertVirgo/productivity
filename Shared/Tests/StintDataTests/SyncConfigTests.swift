import Testing
@testable import StintData

@Suite struct SyncConfigTests {
    @Test func missingEmptyOrUnexpandedIsNil() {
        #expect(SyncConfig.client(info: nil) == nil)
        #expect(SyncConfig.client(info: ["StintSupabaseURL": "", "StintSupabaseAnonKey": ""]) == nil) // Release override
        #expect(SyncConfig.client(info: ["StintSupabaseURL": "$(STINT_SUPABASE_URL)", "StintSupabaseAnonKey": "k"]) == nil)
    }
    @Test func configured() {
        #expect(SyncConfig.client(info: ["StintSupabaseURL": "http://127.0.0.1:54321", "StintSupabaseAnonKey": "k"]) != nil)
    }
}
