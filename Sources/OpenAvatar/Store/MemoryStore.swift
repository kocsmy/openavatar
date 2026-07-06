import Foundation
import GRDB

// MARK: - Memory models

enum FactCategory: String, Codable, CaseIterable, Sendable {
    case identity      // who the user is: role, team, company
    case preference    // how they like things done
    case project       // what they're working on
    case person        // teammates, collaborators, shorthand names
    case commitment    // open promises: "I'll send X by Friday"
    case pattern       // recurring behaviors: "always posts release notes to #eng"

    var displayName: String { rawValue.capitalized }
}

struct MemoryFact: Identifiable, Codable, Sendable {
    var id = UUID()
    var category: FactCategory
    var content: String
    var salience: Double        // 1–5; reinforced facts rise, stale facts decay
    var status: String = "active"
    var sourceCallID: UUID?
    var createdAt = Date()
    var lastReinforcedAt = Date()
}

// MARK: - ContextStore memory extension

/// The compounding "personal Jarvis" memory (improvement #1): every call is
/// minimized to a digest + durable facts; a token-budgeted briefing feeds the
/// detector and planner so the assistant knows the user better over time.
extension ContextStore {

    // MARK: Facts

    func insertFact(_ fact: MemoryFact) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO memory_facts (id, category, content, salience, status,
                    source_call_id, created_at, last_reinforced_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [fact.id.uuidString, fact.category.rawValue, fact.content,
                                 fact.salience, fact.status, fact.sourceCallID?.uuidString,
                                 fact.createdAt.timeIntervalSince1970,
                                 fact.lastReinforcedAt.timeIntervalSince1970])
        }
    }

    func reinforceFact(id: UUID, newContent: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE memory_facts
                SET salience = MIN(5.0, salience + 0.5),
                    last_reinforced_at = ?,
                    content = COALESCE(?, content)
                WHERE id = ?
                """, arguments: [Date().timeIntervalSince1970, newContent, id.uuidString])
        }
    }

    func retireFact(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE memory_facts SET status = 'retired' WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    func activeFacts(category: FactCategory? = nil, limit: Int = 500) throws -> [MemoryFact] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM memory_facts WHERE status = 'active'"
            var args: [DatabaseValueConvertible] = []
            if let category {
                sql += " AND category = ?"
                args.append(category.rawValue)
            }
            sql += " ORDER BY salience DESC, last_reinforced_at DESC LIMIT \(limit)"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map(Self.factFromRow)
        }
    }

    private static func factFromRow(_ row: Row) -> MemoryFact {
        MemoryFact(
            id: UUID(uuidString: row["id"] as String? ?? "") ?? UUID(),
            category: FactCategory(rawValue: row["category"] as String? ?? "") ?? .pattern,
            content: row["content"] as String? ?? "",
            salience: row["salience"] as Double? ?? 1,
            status: row["status"] as String? ?? "active",
            sourceCallID: (row["source_call_id"] as String?).flatMap(UUID.init(uuidString:)),
            createdAt: Date(timeIntervalSince1970: row["created_at"] as Double? ?? 0),
            lastReinforcedAt: Date(timeIntervalSince1970: row["last_reinforced_at"] as Double? ?? 0))
    }

    /// Minimization: cap active memory; retire the least salient, least
    /// recently reinforced facts beyond the cap, and decay stale salience.
    func pruneMemory(maxActiveFacts: Int = 300) throws {
        try dbQueue.write { db in
            // Decay: facts untouched for 30+ days lose salience.
            let monthAgo = Date().timeIntervalSince1970 - 30 * 86_400
            try db.execute(sql: """
                UPDATE memory_facts SET salience = MAX(0.5, salience - 0.5)
                WHERE status = 'active' AND last_reinforced_at < ?
                """, arguments: [monthAgo])
            // Cap: retire overflow beyond the budget.
            try db.execute(sql: """
                UPDATE memory_facts SET status = 'retired' WHERE id IN (
                    SELECT id FROM memory_facts WHERE status = 'active'
                    ORDER BY salience ASC, last_reinforced_at ASC
                    LIMIT MAX(0, (SELECT COUNT(*) FROM memory_facts WHERE status = 'active') - ?)
                )
                """, arguments: [maxActiveFacts])
        }
    }

    // MARK: Digests

    func insertDigest(callID: UUID, digest: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO call_digests (call_id, digest, created_at) VALUES (?, ?, ?)
                ON CONFLICT(call_id) DO UPDATE SET digest = excluded.digest
                """, arguments: [callID.uuidString, digest, Date().timeIntervalSince1970])
        }
    }

    func recentDigests(limit: Int = 10) throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT digest, created_at FROM call_digests
                ORDER BY created_at DESC LIMIT ?
                """, arguments: [limit])
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return rows.map { row in
                let when = Date(timeIntervalSince1970: row["created_at"] as Double? ?? 0)
                return "[\(df.string(from: when))] \(row["digest"] as String? ?? "")"
            }
        }
    }

    // MARK: Briefing (the injected global context)

    /// Compact, token-budgeted "what I know about the user" block for LLM
    /// prompts. Highest-salience facts first, grouped by category, plus the
    /// last few call digests for temporal grounding.
    func memoryBriefing(maxChars: Int = 2500) -> String {
        guard let facts = try? activeFacts(), !facts.isEmpty || !((try? recentDigests(limit: 3)) ?? []).isEmpty else {
            return ""
        }
        var lines: [String] = []
        for category in FactCategory.allCases {
            let inCategory = facts.filter { $0.category == category }
            guard !inCategory.isEmpty else { continue }
            lines.append("\(category.displayName):")
            for fact in inCategory.prefix(12) {
                lines.append("- \(fact.content)")
            }
        }
        if let digests = try? recentDigests(limit: 3), !digests.isEmpty {
            lines.append("Recent calls:")
            lines.append(contentsOf: digests.map { "- \($0)" })
        }
        var out = ""
        for line in lines {
            if out.count + line.count + 1 > maxChars { break }
            out += line + "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Open commitments feed the proactive engine.
    func openCommitments() throws -> [MemoryFact] {
        try activeFacts(category: .commitment)
    }

    /// All segments of a call, for consolidation.
    func allSegments(callID: UUID) throws -> [TranscriptSegment] {
        try recentSegments(callID: callID, seconds: 1_000_000_000)
    }
}
