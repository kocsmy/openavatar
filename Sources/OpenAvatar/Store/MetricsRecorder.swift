import Foundation
import GRDB

/// PRD §7 metrics, instrumented from day one (spec §6). All local; CSV export.
struct MetricsRecorder {
    let store: ContextStore

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    static func today() -> String { dayFormatter.string(from: Date()) }

    /// Increment one of the metrics_daily counters for today.
    func bump(_ column: String, by amount: Int = 1) throws {
        let allowed = ["decisions_detected", "auto_approved_no_edit", "edited",
                       "reverted", "dismissed", "executed"]
        guard allowed.contains(column) else { return }
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO metrics_daily (date, \(column)) VALUES (?, ?)
                ON CONFLICT(date) DO UPDATE SET \(column) = \(column) + ?
                """,
                arguments: [Self.today(), amount, amount])
        }
    }

    func setBaseline(minutes: Int) throws {
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO metrics_daily (date, admin_minutes_baseline) VALUES (?, ?)
                ON CONFLICT(date) DO UPDATE SET admin_minutes_baseline = ?
                """,
                arguments: [Self.today(), minutes, minutes])
        }
    }

    struct DailyRow: Identifiable {
        var id: String { date }
        let date: String
        let decisionsDetected: Int
        let autoApprovedNoEdit: Int
        let edited: Int
        let reverted: Int
        let dismissed: Int
        let executed: Int
        let adminMinutesBaseline: Int

        /// Primary metric: approved w/o edit ÷ decisions surfaced.
        var autoApproveNoEditRate: Double {
            decisionsDetected > 0 ? Double(autoApprovedNoEdit) / Double(decisionsDetected) : 0
        }

        /// Trust signal: reverted ÷ executed.
        var revertRate: Double {
            executed > 0 ? Double(reverted) / Double(executed) : 0
        }
    }

    func fetchAll() throws -> [DailyRow] {
        try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM metrics_daily ORDER BY date DESC")
            return rows.map { row in
                DailyRow(
                    date: row["date"] as String? ?? "",
                    decisionsDetected: row["decisions_detected"] as Int? ?? 0,
                    autoApprovedNoEdit: row["auto_approved_no_edit"] as Int? ?? 0,
                    edited: row["edited"] as Int? ?? 0,
                    reverted: row["reverted"] as Int? ?? 0,
                    dismissed: row["dismissed"] as Int? ?? 0,
                    executed: row["executed"] as Int? ?? 0,
                    adminMinutesBaseline: row["admin_minutes_baseline"] as Int? ?? 0)
            }
        }
    }

    func exportCSV() throws -> String {
        var lines = ["date,decisions_detected,auto_approved_no_edit,edited,reverted,dismissed,executed,admin_minutes_baseline"]
        for r in try fetchAll().reversed() {
            lines.append("\(r.date),\(r.decisionsDetected),\(r.autoApprovedNoEdit),\(r.edited),\(r.reverted),\(r.dismissed),\(r.executed),\(r.adminMinutesBaseline)")
        }
        return lines.joined(separator: "\n")
    }
}
