import Foundation

/// Home surface: what the app is doing right now, and the shortcuts to change it.
///
/// Returns nil for any method that isn't its own — AppBridge tries the next
/// bridge. The TypeScript half of this contract lives in
/// web/src/lib/types/home.ts.
@MainActor
final class HomeBridge {
    private let app = AppState.shared
    private let settings = SettingsStore.shared

    func handle(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        default: return nil
        }
    }
}
