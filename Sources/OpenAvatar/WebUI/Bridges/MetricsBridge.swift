import Foundation

/// Metrics surface: detection and execution counters.
///
/// Returns nil for any method that isn't its own — AppBridge tries the next
/// bridge. The TypeScript half of this contract lives in
/// web/src/lib/types/metrics.ts.
@MainActor
final class MetricsBridge {
    private let app = AppState.shared
    private let settings = SettingsStore.shared

    func handle(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        default: return nil
        }
    }
}
