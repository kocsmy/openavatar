import Foundation
import GRDB

/// The compounding context store (spec §4.9). SQLite via GRDB.
/// Transcripts, decisions, actions, outcomes, entities, metrics — all local.
/// Tokens/keys are NEVER stored here (Keychain only).
final class ContextStore {
    static let shared = try! ContextStore(path: AppPaths.database.path)

    let dbQueue: DatabaseQueue

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    init(inMemory: Bool) throws {
        dbQueue = try DatabaseQueue()
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE calls (
                    id TEXT PRIMARY KEY,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    app TEXT,
                    participants_guess TEXT,
                    summary TEXT
                );
                CREATE TABLE transcript_segments (
                    id TEXT PRIMARY KEY,
                    call_id TEXT NOT NULL,
                    t0 REAL NOT NULL,
                    t1 REAL NOT NULL,
                    source TEXT NOT NULL,
                    text TEXT NOT NULL,
                    confidence REAL NOT NULL
                );
                CREATE INDEX idx_segments_call ON transcript_segments(call_id);
                CREATE TABLE decisions (
                    id TEXT PRIMARY KEY,
                    call_id TEXT,
                    quote TEXT NOT NULL,
                    intent TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    assignee_hint TEXT,
                    confidence REAL NOT NULL,
                    addressed_to_assistant INTEGER NOT NULL DEFAULT 0,
                    source TEXT NOT NULL DEFAULT 'mic',
                    status TEXT NOT NULL,
                    dismiss_reason TEXT,
                    created_at REAL NOT NULL
                );
                CREATE TABLE actions (
                    id TEXT PRIMARY KEY,
                    decision_id TEXT,
                    integration TEXT NOT NULL,
                    tool TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    result_json TEXT,
                    executed_at REAL,
                    reverted_at REAL,
                    edited_before_approve INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE entities (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    name TEXT NOT NULL,
                    aliases_json TEXT NOT NULL DEFAULT '[]',
                    UNIQUE(kind, name)
                );
                CREATE TABLE metrics_daily (
                    date TEXT PRIMARY KEY,
                    decisions_detected INTEGER NOT NULL DEFAULT 0,
                    auto_approved_no_edit INTEGER NOT NULL DEFAULT 0,
                    edited INTEGER NOT NULL DEFAULT 0,
                    reverted INTEGER NOT NULL DEFAULT 0,
                    dismissed INTEGER NOT NULL DEFAULT 0,
                    executed INTEGER NOT NULL DEFAULT 0,
                    admin_minutes_baseline INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE llm_usage (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    at REAL NOT NULL,
                    provider TEXT NOT NULL,
                    model TEXT NOT NULL,
                    task TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL
                );
                """)
        }
        // v2 — compounding memory: per-call digests + long-lived facts about
        // the user (the "personal Jarvis" layer).
        migrator.registerMigration("v2-memory") { db in
            try db.execute(sql: """
                CREATE TABLE call_digests (
                    call_id TEXT PRIMARY KEY,
                    digest TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE memory_facts (
                    id TEXT PRIMARY KEY,
                    category TEXT NOT NULL,        -- identity|preference|project|person|commitment|pattern
                    content TEXT NOT NULL,
                    salience REAL NOT NULL DEFAULT 1.0,
                    status TEXT NOT NULL DEFAULT 'active',   -- active|retired
                    source_call_id TEXT,
                    created_at REAL NOT NULL,
                    last_reinforced_at REAL NOT NULL
                );
                CREATE INDEX idx_facts_status ON memory_facts(status, category);
                """)
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Calls

    @discardableResult
    func startCall(app: String?) throws -> UUID {
        let id = UUID()
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO calls (id, started_at, app) VALUES (?, ?, ?)",
                arguments: [id.uuidString, Date().timeIntervalSince1970, app])
        }
        return id
    }

    func endCall(_ id: UUID, summary: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE calls SET ended_at = ?, summary = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, summary, id.uuidString])
        }
    }

    // MARK: - Transcript

    func insert(_ segments: [TranscriptSegment], callID: UUID) throws {
        try dbQueue.write { db in
            for s in segments {
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments (id, call_id, t0, t1, source, text, confidence)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [s.id.uuidString, callID.uuidString, s.t0, s.t1,
                                s.source.rawValue, s.text, s.confidence])
            }
        }
    }

    // MARK: - Decisions

    func insert(_ decision: Decision) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO decisions (id, call_id, quote, intent, summary, assignee_hint,
                    confidence, addressed_to_assistant, source, status, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [decision.id.uuidString, decision.callID?.uuidString, decision.quote,
                            decision.intent.rawValue, decision.summary, decision.assigneeHint,
                            decision.confidence, decision.addressedToAssistant,
                            decision.source.rawValue, decision.status.rawValue,
                            decision.createdAt.timeIntervalSince1970])
        }
        try MetricsRecorder(store: self).bump("decisions_detected")
    }

    func updateDecisionStatus(_ id: UUID, status: DecisionStatus, dismissReason: DismissReason? = nil) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE decisions SET status = ?, dismiss_reason = ? WHERE id = ?",
                arguments: [status.rawValue, dismissReason?.rawValue, id.uuidString])
        }
    }

    // MARK: - Actions

    func recordAction(id: UUID, decisionID: UUID?, step: ActionStep,
                      result: ActionResult?, editedBeforeApprove: Bool) throws {
        var resultJSON: String?
        if let result, let data = try? JSONEncoder().encode(result) {
            resultJSON = String(data: data, encoding: .utf8)
        }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO actions (id, decision_id, integration, tool, payload_json,
                    result_json, executed_at, edited_before_approve)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [id.uuidString, decisionID?.uuidString, step.integration.rawValue,
                            step.tool, step.arguments.encodedString(), resultJSON,
                            result?.executedAt.timeIntervalSince1970,
                            editedBeforeApprove])
        }
    }

    func markActionReverted(_ id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE actions SET reverted_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, id.uuidString])
        }
        try MetricsRecorder(store: self).bump("reverted")
    }

    /// Graduated autonomy input (spec §4.7): approved executions of this action
    /// type that were never reverted and not edited before approval.
    func cleanApprovedExecutions(qualifiedTool: String) throws -> Int {
        let parts = qualifiedTool.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return 0 }
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM actions
                WHERE integration = ? AND tool = ? AND executed_at IS NOT NULL
                  AND reverted_at IS NULL AND edited_before_approve = 0
                """, arguments: [parts[0], parts[1]]) ?? 0
        }
    }

    // MARK: - Entities

    func upsertEntity(kind: String, name: String, aliases: [String] = []) throws {
        let aliasesJSON = JSONValue.array(aliases.map { .string($0) }).encodedString()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO entities (id, kind, name, aliases_json) VALUES (?, ?, ?, ?)
                ON CONFLICT(kind, name) DO UPDATE SET aliases_json = excluded.aliases_json
                """,
                arguments: [UUID().uuidString, kind, name, aliasesJSON])
        }
    }

    // MARK: - Retrieval (keyword + recency, spec §4.9; no embeddings in v1)

    /// Builds a compact context block for the planner: matching entities,
    /// recent similar decisions and their action outcomes.
    func plannerContext(keywords: [String], limit: Int = 12) throws -> String {
        try dbQueue.read { db in
            var lines: [String] = []

            let entities = try Row.fetchAll(db, sql: "SELECT kind, name, aliases_json FROM entities LIMIT 100")
            if !entities.isEmpty {
                lines.append("Known entities:")
                for row in entities {
                    lines.append("- [\(row["kind"] as String? ?? "")] \(row["name"] as String? ?? "")")
                }
            }

            var sql = """
                SELECT d.summary, d.intent, d.status, d.created_at,
                       a.integration, a.tool, a.result_json
                FROM decisions d LEFT JOIN actions a ON a.decision_id = d.id
                """
            var args: [DatabaseValueConvertible] = []
            let terms = keywords.filter { $0.count > 2 }.prefix(6)
            if !terms.isEmpty {
                let clauses = terms.map { _ in "(d.summary LIKE ? OR d.quote LIKE ?)" }
                sql += " WHERE " + clauses.joined(separator: " OR ")
                for t in terms { args.append("%\(t)%"); args.append("%\(t)%") }
            }
            sql += " ORDER BY d.created_at DESC LIMIT \(limit)"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            if !rows.isEmpty {
                lines.append("Recent related decisions and outcomes:")
                for row in rows {
                    let when = Date(timeIntervalSince1970: row["created_at"] as Double? ?? 0)
                    let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
                    var line = "- \(df.string(from: when)) [\(row["status"] as String? ?? "")] \(row["summary"] as String? ?? "")"
                    if let integration = row["integration"] as String?, let tool = row["tool"] as String? {
                        line += " → \(integration).\(tool)"
                        if let resultJSON = row["result_json"] as String?,
                           let result = try? JSONDecoder().decode(ActionResult.self, from: Data(resultJSON.utf8)) {
                            line += " (\(result.summary)\(result.url.map { ", \($0)" } ?? ""))"
                        }
                    }
                    lines.append(line)
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Rolling window source for the decision detector. Segment timestamps are
    /// call-relative (seconds since capture start), so the cutoff is taken
    /// relative to the newest segment in the call, not wall-clock time.
    func recentSegments(callID: UUID, seconds: TimeInterval) throws -> [TranscriptSegment] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, t0, t1, source, text, confidence FROM transcript_segments
                WHERE call_id = ?
                  AND t1 >= (SELECT MAX(t1) FROM transcript_segments WHERE call_id = ?) - ?
                ORDER BY t0
                """, arguments: [callID.uuidString, callID.uuidString, seconds])
            return rows.map { row in
                TranscriptSegment(
                    id: UUID(uuidString: row["id"] as String? ?? "") ?? UUID(),
                    text: row["text"] as String? ?? "",
                    t0: row["t0"] as Double? ?? 0,
                    t1: row["t1"] as Double? ?? 0,
                    source: AudioSource(rawValue: row["source"] as String? ?? "mic") ?? .mic,
                    confidence: row["confidence"] as Double? ?? 0)
            }
        }
    }

    // MARK: - LLM usage accounting (spec §4.3)

    func recordUsage(provider: ProviderID, model: String, task: LLMTask, usage: Usage) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO llm_usage (at, provider, model, task, input_tokens, output_tokens)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [Date().timeIntervalSince1970, provider.rawValue, model,
                            task.rawValue, usage.inputTokens, usage.outputTokens])
        }
    }

    // MARK: - Export / erase (spec §4.9)

    func exportAllJSON() throws -> Data {
        try dbQueue.read { db in
            var export: [String: JSONValue] = [:]
            let tables = ["calls", "transcript_segments", "decisions", "actions",
                          "entities", "metrics_daily", "llm_usage",
                          "call_digests", "memory_facts"]
            for table in tables {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table)")
                export[table] = .array(rows.map { row in
                    var obj: [String: JSONValue] = [:]
                    for (column, dbValue) in row {
                        switch dbValue.storage {
                        case .null: obj[column] = .null
                        case .int64(let i): obj[column] = .number(Double(i))
                        case .double(let d): obj[column] = .number(d)
                        case .string(let s): obj[column] = .string(s)
                        case .blob(let data): obj[column] = .string(data.base64EncodedString())
                        }
                    }
                    return .object(obj)
                })
            }
            return try JSONValue.object(export).encodedData(pretty: true)
        }
    }

    func deleteAllData() throws {
        try dbQueue.write { db in
            for table in ["calls", "transcript_segments", "decisions", "actions",
                          "entities", "metrics_daily", "llm_usage",
                          "call_digests", "memory_facts"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}
