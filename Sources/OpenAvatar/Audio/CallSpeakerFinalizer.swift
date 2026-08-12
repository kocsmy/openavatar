import Foundation

/// The end-of-call speaker pass: re-cluster the whole recording, then rewrite
/// the call's transcript to match.
///
/// Live labels are a guess made 15 seconds at a time; this is the correction.
/// It decides how many people were actually on the call (bounded by the
/// calendar roster when there is one), attaches names only where the evidence
/// supports it, and deletes the provisional voices the streaming pass invented
/// along the way — those strays are what used to pile up in the database as
/// "Speaker 52" and then contaminate later calls.
actor CallSpeakerFinalizer {

    /// How close a cluster's centroid must sit to a stored voice before we
    /// reuse that person's name. Deliberately strict: a false match here is
    /// the "someone who wasn't on the call" bug, and an unnamed voice the user
    /// can name in one click is much cheaper than a confidently wrong one.
    static let identityDistance: Float = 0.35

    /// A voice earns a permanent fingerprint only after this much speech.
    /// Below it we still show the voice on the call, but never remember it —
    /// short fragments make weak centroids, and weak centroids are what
    /// poisoned matching in the first place.
    static let minSpeechForNewVoice: TimeInterval = 30

    /// Fraction of a cluster's segments that must already agree on a named
    /// voice before we keep that name without a centroid match.
    static let liveAgreementShare = 0.8

    struct Outcome: Sendable, Equatable {
        var voices = 0        // distinct people on the finished call
        var reassigned = 0    // transcript segments whose speaker changed
        var removed = 0       // provisional fingerprints swept away
    }

    private let store: ContextStore
    private let backend: OfflineDiarizerBackend

    init(store: ContextStore = .shared,
         backend: OfflineDiarizerBackend = FluidOfflineDiarizerBackend()) {
        self.store = store
        self.backend = backend
    }

    /// Re-diarize `audioURL` and rewrite the call's speakers. Best-effort: on
    /// any failure the call simply keeps its streaming labels.
    @discardableResult
    func finalize(callID: UUID, audioURL: URL, maxSpeakers: Int?) async -> Outcome {
        do {
            let turns = try await backend.diarize(fileURL: audioURL, maxSpeakers: maxSpeakers)
            guard !turns.isEmpty else { return Outcome() }
            return try apply(turns: turns, callID: callID)
        } catch {
            NSLog("Offline speaker pass failed, keeping live labels: %@",
                  Redactor.redact(error.localizedDescription))
            return Outcome()
        }
    }

    // MARK: Applying the result

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
            guard let profileID = try identify(cluster, members: members, stored: stored) else { continue }
            resolved[cluster.backendSpeakerID] = profileID
        }
        // Distinct people, not distinct clusters: two clusters that both match
        // one stored voice are that person, found twice.
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

    /// Which fingerprint a cluster belongs to: an existing voice it matches
    /// acoustically, the name the live pass already agreed on, a fresh
    /// fingerprint if it spoke enough to be worth remembering — or nothing.
    private func identify(_ cluster: VoiceCluster, members: [TranscriptSegment],
                          stored: [SpeakerProfile]) throws -> UUID? {
        if let match = Self.nearestNamed(to: cluster.centroid, among: stored) { return match }
        if let agreed = Self.liveConsensus(members, stored: stored) { return agreed }
        // A fingerprint with no vector behind it could never be matched again,
        // so it would only ever be clutter.
        guard cluster.speech >= Self.minSpeechForNewVoice, !cluster.centroid.isEmpty else { return nil }
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

    /// The closest NAMED stored voice within the identity threshold. Unnamed
    /// fingerprints are deliberately not candidates — matching a cluster to
    /// last week's "Speaker 12" gains nothing and spreads its errors.
    static func nearestNamed(to centroid: [Float], among stored: [SpeakerProfile]) -> UUID? {
        guard !centroid.isEmpty else { return nil }
        var best: (id: UUID, distance: Float)?
        for profile in stored where profile.isNamed {
            let distance = voiceCosineDistance(centroid, profile.embedding)
            guard distance <= identityDistance else { continue }
            if best == nil || distance < best!.distance { best = (profile.id, distance) }
        }
        return best?.id
    }

    /// What the live pass called this cluster, if it was near-unanimous about
    /// a named voice. Keeps a correct in-call identification (or a name the
    /// user typed mid-call) from being thrown away when the offline centroid
    /// lands just outside the matching threshold.
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
