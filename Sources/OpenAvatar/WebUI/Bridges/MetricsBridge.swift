import Foundation
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

/// Metrics surface: local detection/execution counters (spec §6). No
/// telemetry leaves the machine; CSV export mirrors the native panel.
///
/// Returns nil for any method that isn't its own — AppBridge tries the next
/// bridge. The TypeScript half of this contract lives in
/// web/src/lib/types/metrics.ts.
@MainActor
final class MetricsBridge {
    private let app = AppState.shared

    func handle(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        case "metrics.snapshot": return snapshot()
        case "metrics.exportCSV": return exportCSV()
        default: return nil
        }
    }

    private func snapshot() -> JSONValue {
        let rows = (try? MetricsRecorder(store: app.store).fetchAll()) ?? []
        return .object(["rows": .array(rows.map(rowJSON))])
    }

    private func rowJSON(_ row: MetricsRecorder.DailyRow) -> JSONValue {
        .object([
            "date": .string(row.date),
            "decisionsDetected": .number(Double(row.decisionsDetected)),
            "autoApprovedNoEdit": .number(Double(row.autoApprovedNoEdit)),
            "edited": .number(Double(row.edited)),
            "reverted": .number(Double(row.reverted)),
            "dismissed": .number(Double(row.dismissed)),
            "executed": .number(Double(row.executed)),
            "adminMinutesBaseline": .number(Double(row.adminMinutesBaseline))
        ])
    }

    /// Same NSSavePanel flow as the native Export CSV… button, just triggered
    /// from the web page instead of a SwiftUI Button.
    private func exportCSV() -> JSONValue {
#if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "openavatar-metrics.csv"
        guard panel.runModal() == .OK, let url = panel.url else {
            return .object(["message": .string("")])
        }
        do {
            let csv = try MetricsRecorder(store: app.store).exportCSV()
            try Data(csv.utf8).write(to: url)
            return .object(["message": .string("Exported to \(url.lastPathComponent)")])
        } catch {
            return .object(["message": .string("Export failed: \(error.localizedDescription)")])
        }
#else
        return .object(["message": .string("Export needs macOS")])
#endif
    }
}
