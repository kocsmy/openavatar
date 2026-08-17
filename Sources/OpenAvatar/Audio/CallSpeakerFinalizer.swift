import Foundation

/// The end-of-call speaker pass: re-cluster the whole recording, then rewrite
/// the call's transcript to match.
///
/// Voices are strictly PER-CALL. The app used to keep a database of voice
/// fingerprints and match every call against it — and on far-end call audio
/// (whatever survives the codec, echo cancellation, and the other side's mic)
/// that matching cannot be made reliable: with enough named voices on file,
/// something is always "close enough" to a stranger, which is how a
/// two-person call once listed six people who were nowhere near it. So no
/// cluster is ever identified acoustically against stored voices. A name can
/// reach a voice in exactly three ways: the calendar says the call had one
/// other person (see the 1:1 shortcut in `finalize`), a human typed it during
/// the call, or the post-call LLM pass reads it out of the transcript —
/// roster-gated (MemoryConsolidator). Everything else stays "Speaker N".
actor CallSpeakerFinalizer {

    /// A voice earns a fingerprint row only after this much speech. Below it
    /// we still show the voice on the call, but never keep it — short
    /// fragments are noise, not people.
    static let minSpeechForNewVoice: TimeInterval = 30

    /// Fraction of a cluster's segments that must already agree on a named
    /// voice before we keep that name. The only way a name exists at this
    /// point is a human having attached it during the call (mid-call rename,
    /// or the 1:1 prefill) — near-unanimity keeps it from being thrown away.
    static let liveAgreementShare = 0.8

    struct Outcome: Sendable, Equatable {
        var voices = 0        // distinct people on the finished call
        var reassigned = 0    // transcript segments whose speaker changed
        var removed = 0       // provisional fingerprints swept away
    }

    private let store: ContextStore
    private let backend: OfflineDiarizerBackend

    init(store: ContextStore = .shared,
         backend: OfflineDiarizerBackend = SpeakerKitOfflineDiarizerBackend()) {
        self.store = store
        self.backend = backend
    }

    /// Rewrite the call's speakers. Best-effort: on any failure the call
    /// simply keeps its streaming labels.
    ///
    /// `roster` is the meeting's invitee list (the user excluded). With
    /// exactly one name on it this is a 1:1 call, and the entire system
    /// channel IS that person — no clustering, no inference, no audio needed.
    /// Otherwise the recording is re-diarized and voices stay per-call.
    @discardableResult
    func finalize(callID: UUID, audioURL: URL?, maxSpeakers: Int?,
                  roster: [String] = []) async -> Outcome {
        do {
            if roster.count == 1 {
                return try assignAll(callID: callID, to: roster[0])
            }
            guard let audioURL else { return Outcome() }
            let turns = try await backend.diarize(fileURL: audioURL, maxSpeakers: maxSpeakers)
            guard !turns.isEmpty else { return Outcome() }
            return try apply(turns: turns, callID: callID)
        } catch {
            NSLog("Offline speaker pass failed, keeping live labels: %@",
                  Redactor.redact(error.localizedDescription))
            return Outcome()
        }
    }

    // MARK: The 1:1 shortcut

    /// A two-person meeting is the one case with a deterministic answer: the
    /// mic channel is the user, so everything on the system channel belongs
    /// to the single other invitee. Assign it all to one voice wearing their
    /// name, by construction rather than by inference.
    private func assignAll(callID: UUID, to name: String) throws -> Outcome {
        let segments = try store.segments(callID: callID).filter { $0.source == .system }
        guard !segments.isEmpty else { return Outcome() }
        let profileID = try callProfile(named: name, segments: segments)

        var outcome = Outcome()
        outcome.voices = 1
        var updates: [(segmentID: UUID, speakerID: UUID?, label: String?)] = []
        for segment in segments where segment.speakerID != profileID.uuidString {
            updates.append((segment.id, profileID, name))
            outcome.reassigned += 1
        }
        try store.applySpeakerAssignments(callID: callID, updates)
        outcome.removed = try store.deleteUnreferencedUnnamedProfiles()
        try store.relabelUnnamedSpeakers(callID: callID)
        return outcome
    }

    /// The voice that stands for the call's one remote person: whatever
    /// profile the live pass already gave that name on THIS call (the 1:1
    /// prefill, or a rename), else a fresh one. Profiles from other calls are
    /// deliberately not candidates, even by name — voices are per-call.
    private func callProfile(named name: String, segments: [TranscriptSegment]) throws -> UUID {
        let onCall = Set(segments.compactMap { $0.speakerID.flatMap(UUID.init(uuidString:)) })
        if let existing = try store.allSpeakerProfiles()
            .first(where: { onCall.contains($0.id) && $0.name == name }) {
            return existing.id
        }
        let now = Date()
        let profile = SpeakerProfile(id: UUID(), name: name,
                                     ordinal: (try? store.nextSpeakerOrdinal()) ?? 1,
                                     embedding: [], sampleCount: segments.count,
                                     createdAt: now, updatedAt: now)
        try store.insertSpeakerProfile(profile)
        return profile.id
    }

    // MARK: Applying a diarized result

    private func apply(turns: [SpeakerTurn], callID: UUID) throws -> Outcome {
        let segments = try store.segments(callID: callID).filter { $0.source == .system }
        guard !segments.isEmpty else { return Outcome() }

        let clusters = Self.clusters(from: turns)
        let placement = Self.place(turns: turns, segments: segments)
        let stored = try store.allSpeakerProfiles()

        var resolved: [String: UUID] = [:]      // cluster → fingerprint
        var outcome = Outcome()
        for cluster in clusters {
            let members = segments.filter { placement[$0.id] == cluster.backendSpeakerID }
            guard !members.isEmpty else { continue }
            guard let profileID = try identify(cluster, members: members,
                                               stored: stored) else { continue }
            resolved[cluster.backendSpeakerID] = profileID
        }
        // Distinct people, not distinct clusters: two clusters that both kept
        // one live-named voice are that person, found twice.
        outcome.voices = Set(resolved.values).count

        // Named voices carry their name onto the row; unnamed ones are left
        // blank here and numbered per call by relabelUnnamedSpeakers below.
        var nameFor: [UUID: String] = [:]
        for profile in stored where profile.isNamed { nameFor[profile.id] = profile.name }

        var updates: [(segmentID: UUID, speakerID: UUID?, label: String?)] = []
        for segment in segments {
            let profileID = placement[segment.id].flatMap { resolved[$0] }
            // A nil fingerprint means we genuinely don't know who spoke,
            // which reads as "Others" rather than as a speaker we made up.
            guard profileID?.uuidString != segment.speakerID else { continue }
            updates.append((segment.id, profileID, profileID.flatMap { nameFor[$0] }))
            outcome.reassigned += 1
        }
        try store.applySpeakerAssignments(callID: callID, updates)
        outcome.removed = try store.deleteUnreferencedUnnamedProfiles()
        try store.relabelUnnamedSpeakers(callID: callID)
        return outcome
    }

    /// Which fingerprint a cluster belongs to: the name a human attached
    /// during the call (carried by the live labels), a fresh per-call voice
    /// if it spoke enough to be worth keeping — or nothing. Never an acoustic
    /// match against stored voices; that is the recognition this pass no
    /// longer performs.
    private func identify(_ cluster: VoiceCluster, members: [TranscriptSegment],
                          stored: [SpeakerProfile]) throws -> UUID? {
        if let agreed = Self.liveConsensus(members, stored: stored) { return agreed }
        guard cluster.speech >= Self.minSpeechForNewVoice else { return nil }
        let now = Date()
        let profile = SpeakerProfile(id: UUID(), name: nil,
                                     ordinal: (try? store.nextSpeakerOrdinal()) ?? 1,
                                     embedding: cluster.centroid, sampleCount: members.count,
                                     createdAt: now, updatedAt: now)
        try store.insertSpeakerProfile(profile)
        return profile.id
    }

    // MARK: Pure helpers (pinned by tests)

    /// One acoustic voice found in the recording.
    struct VoiceCluster: Equatable, Sendable {
        let backendSpeakerID: String
        /// Duration-weighted mean of the cluster's turn embeddings.
        let centroid: [Float]
        /// Total seconds this voice spent talking.
        let speech: TimeInterval
    }

    static func clusters(from turns: [SpeakerTurn]) -> [VoiceCluster] {
        var order: [String] = []
        var totals: [String: TimeInterval] = [:]
        var sums: [String: [Float]] = [:]
        for turn in turns {
            let seconds = max(0, turn.end - turn.start)
            guard seconds > 0 else { continue }
            if totals[turn.backendSpeakerID] == nil { order.append(turn.backendSpeakerID) }
            totals[turn.backendSpeakerID, default: 0] += seconds
            guard !turn.embedding.isEmpty else { continue }
            var running = sums[turn.backendSpeakerID] ?? [Float](repeating: 0, count: turn.embedding.count)
            guard running.count == turn.embedding.count else { continue }
            for i in running.indices { running[i] += turn.embedding[i] * Float(seconds) }
            sums[turn.backendSpeakerID] = running
        }
        return order.map { id in
            VoiceCluster(backendSpeakerID: id,
                         centroid: sums[id] ?? [],
                         speech: totals[id] ?? 0)
        }
    }

    /// Transcript segment → cluster, by majority time-overlap. Reuses the
    /// live path's join so both agree on what "this span belongs to that
    /// voice" means.
    static func place(turns: [SpeakerTurn], segments: [TranscriptSegment]) -> [UUID: String] {
        var idForCluster: [String: UUID] = [:]
        var clusterForID: [UUID: String] = [:]
        var timeline = SpeakerTimeline()
        for turn in turns {
            let key: UUID
            if let existing = idForCluster[turn.backendSpeakerID] {
                key = existing
            } else {
                key = UUID()
                idForCluster[turn.backendSpeakerID] = key
                clusterForID[key] = turn.backendSpeakerID
            }
            timeline.add(speakerID: key, start: turn.start, end: turn.end)
        }
        var out: [UUID: String] = [:]
        for segment in segments {
            guard let key = timeline.speaker(overlapping: segment.t0, segment.t1),
                  let cluster = clusterForID[key] else { continue }
            out[segment.id] = cluster
        }
        return out
    }

    /// What the live pass called this cluster, if it was near-unanimous about
    /// a named voice. Names only exist live when a human attached one during
    /// the call — this keeps that from being thrown away by the re-cluster.
    static func liveConsensus(_ members: [TranscriptSegment],
                              stored: [SpeakerProfile]) -> UUID? {
        guard !members.isEmpty else { return nil }
        let named = Set(stored.filter(\.isNamed).map(\.id.uuidString))
        var counts: [String: Int] = [:]
        for member in members {
            guard let sid = member.speakerID, named.contains(sid) else { continue }
            counts[sid, default: 0] += 1
        }
        guard let (sid, count) = counts.max(by: { $0.value < $1.value }),
              Double(count) >= Double(members.count) * liveAgreementShare else { return nil }
        return UUID(uuidString: sid)
    }
}
