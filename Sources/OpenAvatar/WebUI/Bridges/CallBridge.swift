import Foundation

/// Call notes surface: live transcript, speakers, and in-call decisions.
///
/// Returns nil for any method that isn't its own — AppBridge tries the next
/// bridge. The TypeScript half of this contract lives in
/// web/src/lib/types/call.ts.
@MainActor
final class CallBridge {
    private let app = AppState.shared
    private let settings = SettingsStore.shared

    func handle(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        default: return nil
        }
    }
}
