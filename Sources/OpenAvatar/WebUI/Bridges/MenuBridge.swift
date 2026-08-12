import Foundation

/// Menu-bar surface: the popover's state, decisions, and controls.
///
/// Returns nil for any method that isn't its own — AppBridge tries the next
/// bridge. The TypeScript half of this contract lives in
/// web/src/lib/types/menu.ts.
@MainActor
final class MenuBridge {
    private let app = AppState.shared
    private let settings = SettingsStore.shared

    func handle(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        default: return nil
        }
    }
}
