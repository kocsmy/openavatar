import Foundation
import GRDB

/// The compounding context store (spec §4.9). SQLite via GRDB.
/// Transcripts, decisions, actions, outcomes, entities, metrics — all local.
/// Tokens/keys are NEVER stored here (Keychain only).
final class ContextStore: @unchecked Sendable {
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
        // v3 — per-voice diarization label on each transcript segment.
        migrator.registerMigration("v3-speaker") { db in
            try db.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN speaker TEXT")
        }
        // v4 — persistent voice fingerprints: a speaker's name is stored against
        // its acoustic embedding and carries across every call. Segments keep a
        // stable speaker_id so renaming a voice relabels its whole history.
        migrator.registerMigration("v4-speaker-profiles") { db in
            try db.execute(sql: """
                CREATE TABLE speaker_profiles (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    ordinal INTEGER NOT NULL,
                    embedding BLOB NOT NULL,
                    sample_count INTEGER NOT NULL DEFAULT 1,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                ALTER TABLE transcript_segments ADD COLUMN speaker_id TEXT;
                CREATE INDEX idx_segments_speaker ON transcript_segments(speaker_id);
                """)
        }
        // v5 — Follow-ups: time-referenced items to revisit, with reminders.
        migrator.registerMigration("v5-followups") { db in
            try db.execute(sql: """
                CREATE TABLE followups (
                    id TEXT PRIMARY KEY,
                    call_id TEXT,
                    title TEXT NOT NULL,
                    quote TEXT,
                    due_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    status TEXT NOT NULL DEFAULT 'suggested'
                );
                CREATE INDEX idx_followups_status ON followups(status, due_at);
                """)
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Follow-ups

    private static func followUp(from row: Row) -> FollowUp? {
        guard let id = UUID(uuidString: row["id"] as String? ?? "") else { return nil }
        return FollowUp(
            id: id,
            callID: (row["call_id"] as String?).flatMap { UUID(uuidString: $0) },
            title: row["title"] as String? ?? "",
            quote: row["quote"] as String?,
            dueAt: Date(timeIntervalSince1970: row["due_at"] as Double? ?? 0),
            createdAt: Date(timeIntervalSince1970: row["created_at"] as Double? ?? 0),
            status: FollowUpStatus(rawValue: row["status"] as String? ?? "") ?? .suggested)
    }

    func insertFollowUp(_ f: FollowUp) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO followups (id, call_id, title, quote, due_at, created_at, status)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [f.id.uuidString, f.callID?.uuidString, f.title, f.quote,
                                 f.dueAt.timeIntervalSince1970, f.createdAt.timeIntervalSince1970,
                                 f.status.rawValue])
        }
    }

    /// Follow-ups with the given statuses, soonest-due first.
    func followUps(statuses: [FollowUpStatus]) throws -> [FollowUp] {
        try dbQueue.read { db in
            let placeholders = statuses.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM followups WHERE status IN (\(placeholders)) ORDER BY due_at
                """, arguments: StatementArguments(statuses.map { $0.rawValue }))
            return rows.compactMap(Self.followUp(from:))
        }
    }

    func updateFollowUpStatus(id: UUID, status: FollowUpStatus) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE followups SET status = ? WHERE id = ?",
                           arguments: [status.rawValue, id.uuidString])
        }
    }

    func updateFollowUpDue(id: UUID, dueAt: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE followups SET due_at = ? WHERE id = ?",
                           arguments: [dueAt.timeIntervalSince1970, id.uuidString])
        }
    }

    func deleteFollowUp(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM followups WHERE id = ?", arguments: [id.uuidString])
        }
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

    // MARK: - Calls (browsing)

    struct CallRecord: Identifiable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date?
        let app: String?
        let summary: String?
    }

    func listCalls(limit: Int = 200) throws -> [CallRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, started_at, ended_at, app, summary FROM calls
                ORDER BY started_at DESC LIMIT ?
                """, arguments: [limit])
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"] as String? ?? "") else { return nil }
                let ended = row["ended_at"] as Double?
                return CallRecord(
                    id: id,
                    startedAt: Date(timeIntervalSince1970: row["started_at"] as Double? ?? 0),
                    endedAt: ended.map(Date.init(timeIntervalSince1970:)),
                    app: row["app"] as String?,
                    summary: row["summary"] as String?)
            }
        }
    }

    /// Full transcript of one call, ordered by time.
    func segments(callID: UUID) throws -> [TranscriptSegment] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, t0, t1, source, text, confidence, speaker, speaker_id FROM transcript_segments
                WHERE call_id = ? ORDER BY t0
                """, arguments: [callID.uuidString])
            return rows.map(Self.segment(from:))
        }
    }

    private static func segment(from row: Row) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(uuidString: row["id"] as String? ?? "") ?? UUID(),
            text: row["text"] as String? ?? "",
            t0: row["t0"] as Double? ?? 0,
            t1: row["t1"] as Double? ?? 0,
            source: AudioSource(rawValue: row["source"] as String? ?? "mic") ?? .mic,
            confidence: row["confidence"] as Double? ?? 0,
            speaker: row["speaker"] as String?,
            speakerID: row["speaker_id"] as String?)
    }

    // MARK: - Transcript

    func insert(_ segments: [TranscriptSegment], callID: UUID) throws {
        try dbQueue.write { db in
            for s in segments {
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments (id, call_id, t0, t1, source, text, confidence, speaker, speaker_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [s.id.uuidString, callID.uuidString, s.t0, s.t1,
                                s.source.rawValue, s.text, s.confidence, s.speaker, s.speakerID])
            }
        }
    }

    /// Remove segments that turned out to be chunk-overlap duplicates of a
    /// newer, fuller decode (see TranscriptSanitizer).
    func deleteSegments(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM transcript_segments WHERE id = ?",
                               arguments: [id.uuidString])
            }
        }
    }

    // MARK: - Speaker profiles (persistent voice fingerprints)

    func allSpeakerProfiles() throws -> [SpeakerProfile] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, ordinal, embedding, sample_count, created_at, updated_at
                FROM speaker_profiles ORDER BY ordinal
                """)
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"] as String? ?? ""),
                      let blob = row["embedding"] as Data? else { return nil }
                return SpeakerProfile(
                    id: id,
                    name: row["name"] as String?,
                    ordinal: row["ordinal"] as Int? ?? 0,
                    embedding: SpeakerProfile.decode(blob),
                    sampleCount: row["sample_count"] as Int? ?? 1,
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double? ?? 0),
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double? ?? 0))
            }
        }
    }

    /// The distinct voices heard on one call (profiles joined through the
    /// call's segments), in first-heard order. Lets the UI scope speaker
    /// management to a call while fingerprints stay global.
    func speakerProfiles(callID: UUID) throws -> [SpeakerProfile] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id, p.name, p.ordinal, p.embedding, p.sample_count,
                       p.created_at, p.updated_at
                FROM speaker_profiles p
                JOIN (SELECT speaker_id, MIN(t0) AS first_t0 FROM transcript_segments
                      WHERE call_id = ? AND speaker_id IS NOT NULL
                      GROUP BY speaker_id) s ON s.speaker_id = p.id
                ORDER BY s.first_t0
                """, arguments: [callID.uuidString])
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"] as String? ?? ""),
                      let blob = row["embedding"] as Data? else { return nil }
                return SpeakerProfile(
                    id: id,
                    name: row["name"] as String?,
                    ordinal: row["ordinal"] as Int? ?? 0,
                    embedding: SpeakerProfile.decode(blob),
                    sampleCount: row["sample_count"] as Int? ?? 1,
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double? ?? 0),
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double? ?? 0))
            }
        }
    }

    /// Next friendly ordinal for a new voice ("Speaker N").
    func nextSpeakerOrdinal() throws -> Int {
        try dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT MAX(ordinal) FROM speaker_profiles") ?? 0) + 1
        }
    }

    func insertSpeakerProfile(_ p: SpeakerProfile) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO speaker_profiles (id, name, ordinal, embedding, sample_count, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [p.id.uuidString, p.name, p.ordinal,
                                 SpeakerProfile.encode(p.embedding), p.sampleCount,
                                 p.createdAt.timeIntervalSince1970, p.updatedAt.timeIntervalSince1970])
        }
    }

    /// Persist an updated running-average centroid after a match.
    func updateSpeakerEmbedding(id: UUID, embedding: [Float], sampleCount: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE speaker_profiles SET embedding = ?, sample_count = ?, updated_at = ? WHERE id = ?
                """, arguments: [SpeakerProfile.encode(embedding), sampleCount,
                                 Date().timeIntervalSince1970, id.uuidString])
        }
    }

    /// Merge the `source` voice into `target`: every transcript segment of the
    /// source is reassigned to the target, their fingerprints are blended
    /// (weighted by how many utterances each has heard) so future speech from
    /// either voice matches the target, and the source profile is removed. If
    /// the target is unnamed but the source has a name, the target adopts it.
    /// Use this to fix over-splitting — one person showing up as several voices.
    func mergeSpeaker(_ source: UUID, into target: UUID) throws {
        guard source != target else { return }
        try dbQueue.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, ordinal, embedding, sample_count
                FROM speaker_profiles WHERE id IN (?, ?)
                """, arguments: [source.uuidString, target.uuidString])
            var byID: [String: (name: String?, ordinal: Int, emb: [Float], n: Int)] = [:]
            for r in rows {
                guard let blob = r["embedding"] as Data? else { continue }
                byID[r["id"] as String? ?? ""] = (
                    r["name"] as String?, r["ordinal"] as Int? ?? 0,
                    SpeakerProfile.decode(blob), r["sample_count"] as Int? ?? 1)
            }
            guard let s = byID[source.uuidString], let t = byID[target.uuidString] else { return }

            // Blend centroids weighted by sample count (only when dimensions
            // match; otherwise keep the target's fingerprint).
            var blended = t.emb
            if s.emb.count == t.emb.count, !t.emb.isEmpty {
                let tn = Float(t.n), sn = Float(s.n)
                for i in 0..<blended.count {
                    blended[i] = (t.emb[i] * tn + s.emb[i] * sn) / (tn + sn)
                }
                var norm: Float = 0
                for v in blended { norm += v * v }
                norm = norm.squareRoot()
                if norm > 0 { for i in 0..<blended.count { blended[i] /= norm } }
            }
            let name = (t.name?.isEmpty ?? true) ? s.name : t.name
            try db.execute(sql: """
                UPDATE speaker_profiles SET embedding = ?, sample_count = ?, name = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [SpeakerProfile.encode(blended), t.n + s.n, name,
                                 Date().timeIntervalSince1970, target.uuidString])

            // Reassign the source's segments to the target and relabel them.
            let label = (name?.isEmpty ?? true) ? "Speaker \(t.ordinal)" : name!
            try db.execute(sql: "UPDATE transcript_segments SET speaker_id = ? WHERE speaker_id = ?",
                           arguments: [target.uuidString, source.uuidString])
            try db.execute(sql: "UPDATE transcript_segments SET speaker = ? WHERE speaker_id = ?",
                           arguments: [label, target.uuidString])

            try db.execute(sql: "DELETE FROM speaker_profiles WHERE id = ?",
                           arguments: [source.uuidString])
        }
    }

    /// Rename a voice. The new name carries to every past segment of that voice
    /// (via speaker_id) and, because the fingerprint persists, to future calls.
    /// Pass nil to clear the name (revert to "Speaker N").
    func renameSpeaker(id: UUID, to name: String?) throws {
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (clean?.isEmpty ?? true) ? nil : clean
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE speaker_profiles SET name = ?, updated_at = ? WHERE id = ?",
                           arguments: [finalName, Date().timeIntervalSince1970, id.uuidString])
            // Relabel past transcript segments. When cleared, fall back to the
            // stored ordinal so the row reads "Speaker N" again.
            if let finalName {
                try db.execute(sql: "UPDATE transcript_segments SET speaker = ? WHERE speaker_id = ?",
                               arguments: [finalName, id.uuidString])
            } else if let ordinal = try Int.fetchOne(db,
                        sql: "SELECT ordinal FROM speaker_profiles WHERE id = ?",
                        arguments: [id.uuidString]) {
                try db.execute(sql: "UPDATE transcript_segments SET speaker = ? WHERE speaker_id = ?",
                               arguments: ["Speaker \(ordinal)", id.uuidString])
            }
        }
    }

    /// One-shot cleanup of accumulated over-splitting: every unnamed voice
    /// with at most `maxSamples` utterances folds into its acoustically
    /// nearest named-or-substantial voice, provided the fingerprints are
    /// close. Backfills calls recorded before end-of-call consolidation
    /// existed. Returns the number of voices folded away.
    ///
    /// The fold bar depends on the fingerprint's vector space (dimension):
    /// neural 256-dim embeddings separate speakers around 0.7 cosine
    /// distance; legacy spectral ones around 0.16. Mismatched dimensions are
    /// infinitely far apart, so legacy and neural profiles never cross-merge.
    func sweepStrayProfiles(maxSamples: Int = 3) throws -> Int {
        let profiles = try allSpeakerProfiles()
        let targets = profiles.filter { $0.isNamed || $0.sampleCount > maxSamples }
        guard !targets.isEmpty else { return 0 }
        var merged = 0
        for stray in profiles where !stray.isNamed && stray.sampleCount <= maxSamples {
            var best: SpeakerProfile?
            var bestDist: Float = .greatestFiniteMagnitude
            for target in targets where target.id != stray.id {
                let dist = voiceCosineDistance(stray.embedding, target.embedding)
                if dist < bestDist { bestDist = dist; best = target }
            }
            let foldBar: Float = stray.embedding.count >= 100 ? 0.80 : 0.25
            if let best, bestDist <= foldBar {
                try mergeSpeaker(stray.id, into: best.id)
                merged += 1
            }
        }
        return merged
    }

    /// Break ONE call's voice out of a profile it was wrongly matched to —
    /// the inverse of merge. The call's segments move to a brand-new unnamed
    /// "Speaker N" profile (rename it afterwards); the source profile keeps its
    /// name, fingerprint and every other call. Use this when a new person got
    /// labeled with an existing person's name. Returns the new profile's id,
    /// or nil when the source had no segments on that call.
    func detachSpeaker(callID: UUID, from source: UUID) throws -> UUID? {
        try dbQueue.write { db in
            let segmentCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_segments WHERE call_id = ? AND speaker_id = ?
                """, arguments: [callID.uuidString, source.uuidString]) ?? 0
            guard segmentCount > 0 else { return nil }

            // The new profile inherits the source's centroid — per-utterance
            // embeddings aren't stored, and this call's voice is what pulled
            // the centroid anyway. Future utterances re-shape it from here.
            guard let row = try Row.fetchOne(db, sql: """
                SELECT embedding, sample_count FROM speaker_profiles WHERE id = ?
                """, arguments: [source.uuidString]),
                  let blob = row["embedding"] as Data? else { return nil }
            let sourceSamples = row["sample_count"] as Int? ?? 1

            let ordinal = (try Int.fetchOne(
                db, sql: "SELECT MAX(ordinal) FROM speaker_profiles") ?? 0) + 1
            let newID = UUID()
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO speaker_profiles (id, name, ordinal, embedding, sample_count, created_at, updated_at)
                VALUES (?, NULL, ?, ?, ?, ?, ?)
                """, arguments: [newID.uuidString, ordinal, blob,
                                 max(1, segmentCount), now, now])

            try db.execute(sql: """
                UPDATE transcript_segments SET speaker_id = ?, speaker = ?
                WHERE call_id = ? AND speaker_id = ?
                """, arguments: [newID.uuidString, "Speaker \(ordinal)",
                                 callID.uuidString, source.uuidString])

            // Give the source back the weight this call contributed so future
            // centroid updates aren't diluted by utterances that left.
            try db.execute(sql: """
                UPDATE speaker_profiles SET sample_count = ?, updated_at = ? WHERE id = ?
                """, arguments: [max(1, sourceSamples - segmentCount), now, source.uuidString])
            return newID
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

    /// All decisions detected on one call, oldest first — used to re-open the
    /// post-call review from history.
    func decisions(callID: UUID) throws -> [Decision] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, call_id, quote, intent, summary, assignee_hint, confidence,
                       addressed_to_assistant, source, status, dismiss_reason, created_at
                FROM decisions WHERE call_id = ? ORDER BY created_at
                """, arguments: [callID.uuidString])
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"] as String? ?? ""),
                      let intent = DecisionIntent(rawValue: row["intent"] as String? ?? ""),
                      let status = DecisionStatus(rawValue: row["status"] as String? ?? "") else { return nil }
                return Decision(
                    id: id,
                    callID: (row["call_id"] as String?).flatMap { UUID(uuidString: $0) },
                    quote: row["quote"] as String? ?? "",
                    intent: intent,
                    summary: row["summary"] as String? ?? "",
                    assigneeHint: row["assignee_hint"] as String?,
                    confidence: row["confidence"] as Double? ?? 0,
                    addressedToAssistant: (row["addressed_to_assistant"] as Int? ?? 0) != 0,
                    source: AudioSource(rawValue: row["source"] as String? ?? "mic") ?? .mic,
                    status: status,
                    dismissReason: (row["dismiss_reason"] as String?).flatMap { DismissReason(rawValue: $0) },
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double? ?? 0))
            }
        }
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
                SELECT id, t0, t1, source, text, confidence, speaker, speaker_id FROM transcript_segments
                WHERE call_id = ?
                  AND t1 >= (SELECT MAX(t1) FROM transcript_segments WHERE call_id = ?) - ?
                ORDER BY t0
                """, arguments: [callID.uuidString, callID.uuidString, seconds])
            return rows.map(Self.segment(from:))
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
                          "call_digests", "memory_facts", "speaker_profiles", "followups"]
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
                          "call_digests", "memory_facts", "speaker_profiles", "followups"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}
