import SwiftUI
import UniformTypeIdentifiers

/// Local metrics dashboard (spec §6). No telemetry leaves the machine;
/// CSV export for dogfooder reporting.
struct MetricsDashboardTab: View {
    @EnvironmentObject var app: AppState
    @State private var rows: [MetricsRecorder.DailyRow] = []
    @State private var message: String?

    private var totals: (detected: Int, noEdit: Int, edited: Int, reverted: Int, executed: Int, dismissed: Int) {
        rows.reduce(into: (0, 0, 0, 0, 0, 0)) { acc, r in
            acc.0 += r.decisionsDetected; acc.1 += r.autoApprovedNoEdit
            acc.2 += r.edited; acc.3 += r.reverted; acc.4 += r.executed
            acc.5 += r.dismissed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                statTile("Auto-approve w/o edit",
                         value: rate(totals.noEdit, of: totals.detected),
                         caption: "primary metric")
                statTile("Revert rate",
                         value: rate(totals.reverted, of: totals.executed),
                         caption: "trust signal")
                statTile("Decisions detected", value: "\(totals.detected)",
                         caption: "all time")
                statTile("Misfires dismissed", value: "\(totals.dismissed)",
                         caption: "R2 log")
            }

            Table(rows) {
                TableColumn("Date", value: \.date)
                TableColumn("Detected") { Text("\($0.decisionsDetected)") }
                TableColumn("No-edit ✓") { Text("\($0.autoApprovedNoEdit)") }
                TableColumn("Edited") { Text("\($0.edited)") }
                TableColumn("Executed") { Text("\($0.executed)") }
                TableColumn("Reverted") { Text("\($0.reverted)") }
                TableColumn("Baseline min") { Text("\($0.adminMinutesBaseline)") }
            }

            HStack {
                Button("Export CSV…") { exportCSV() }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Refresh") { load() }
            }
        }
        .padding()
        .onAppear { load() }
    }

    private func rate(_ numerator: Int, of denominator: Int) -> String {
        guard denominator > 0 else { return "—" }
        return String(format: "%.0f%%", Double(numerator) / Double(denominator) * 100)
    }

    private func statTile(_ title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold))
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func load() {
        rows = (try? MetricsRecorder(store: app.store).fetchAll()) ?? []
    }

    private func exportCSV() {
#if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "openavatar-metrics.csv"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let csv = try MetricsRecorder(store: app.store).exportCSV()
                try Data(csv.utf8).write(to: url)
                message = "Exported to \(url.lastPathComponent)"
            } catch {
                message = "Export failed: \(error.localizedDescription)"
            }
        }
#endif
    }
}
