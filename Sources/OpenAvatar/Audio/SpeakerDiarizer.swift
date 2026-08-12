import Foundation
import FluidAudio

/// The result of diarizing one utterance: a stable voice-fingerprint id plus
/// the label to show (a user-assigned name, or "Speaker N").
struct DiarizedSpeaker: Sendable, Equatable {
    let id: UUID
    let label: String
}

/// One acoustic speaker turn found by the diarization backend, in
/// call-relative seconds.
struct SpeakerTurn: Sendable, Equatable {
    let backendSpeakerID: String
    let embedding: [Float]
    let start: TimeInterval
    let end: TimeInterval
}

/// The diarization engine behind SpeakerDiarizer. Production uses
/// FluidAudio's complete pipeline (pyannote-style segmentation + WeSpeaker
/// embeddings + clustering with a running speaker database); tests inject a
/// scripted fake.
protocol DiarizerBackend {
    var isReady: Bool { get }
    func prepare() async throws
    /// Seed the backend's speaker database with stored fingerprints, so a
    /// returning voice is assigned its existing id instead of a fresh one.
    func enroll(_ known: [(id: String, name: String?, embedding: [Float])])
    /// Full diarization of one audio window; `time` is the window's absolute
    /// call-relative start, so returned turns are on the call clock.
    func diarize(_ samples: [Float], at time: TimeInterval) throws -> [SpeakerTurn]
    /// The backend's evolved centroid per speaker id, read at call end.
    func finalEmbeddings() -> [String: [Float]]
}

/// FluidAudio's complete diarization pipeline. This replaced our homegrown
/// per-utterance nearest-neighbor matching, which embedded whole transcriber
/// utterances — with Parakeet that's a full 15s chunk, often two speakers
/// blended into one garbage embedding. The real pipeline finds acoustic
/// speaker turns inside the audio first, and its SpeakerManager keeps ids
/// consistent across sequential windows.
final class FluidDiarizerBackend: DiarizerBackend {
    private var manager: DiarizerManager?

    var isReady: Bool { manager?.isAvailable ?? false }

    func prepare() async throws {
        if isReady { return }
        let models = try await DiarizerModels.downloadIfNeeded()
        let m = DiarizerManager()   // stock config: the tuned, proven defaults
        m.initialize(models: models)
        manager = m
    }

    func enroll(_ known: [(id: String, name: String?, embedding: [Float])]) {
        guard let manager, !known.isEmpty else { return }
        manager.initializeKnownSpeakers(known.map {
            Speaker(id: $0.id, name: $0.name ?? $0.id, currentEmbedding: $0.embedding,
                    duration: 60, isPermanent: true)
        })
    }

    func diarize(_ samples: [Float], at time: TimeInterval) throws -> [SpeakerTurn] {
        guard let manager else { throw AppError.notConfigured("Diarization models not loaded") }
        return try manager.performCompleteDiarization(samples, atTime: time).segments.map {
            SpeakerTurn(backendSpeakerID: $0.speakerId, embedding: $0.embedding,
                        start: TimeInterval($0.startTimeSeconds),
                        end: TimeInterval($0.endTimeSeconds))
        }
    }

    func finalEmbeddings() -> [String: [Float]] {
        manager?.speakerManager.getAllSpeakers().mapValues(\.currentEmbedding) ?? [:]
    }
}

/// On-device per-voice diarization for the system-audio ("Others") channel.
///
/// Each audio chunk is diarized into timed speaker turns (see
/// DiarizerBackend); transcript segments then take the speaker who did most
/// of the talking in their time range (SpeakerTimeline). Stored fingerprints
/// are enrolled into the backend at call start, so a named voice keeps its
/// name across calls; voices the backend discovers mid-call get persistent
/// "Speaker N" profiles the user can rename. The mic channel is always "You"
/// and never diarized.
actor SpeakerDiarizer {
    private let store: ContextStore
    private let backendFactory: @Sendable () -> DiarizerBackend
    private lazy var backend: DiarizerBackend = backendFactory()

    /// Known voice fingerprints, loaded from the store.
    private var profiles: [SpeakerProfile] = []
    private var loaded = false

    // Per-call working state (cleared by beginCall).
    private var backendToProfile: [String: UUID] = [:]
    private var timeline = SpeakerTimeline()
    private var labeledCounts: [UUID: Int] = [:]
    private var enrolled = false
    /// "Speaker N" numbering scoped to this call, in first-heard order.
    private var callOrdinals: [UUID: Int] = [:]

    init(store: ContextStore = .shared,
         backendFactory: @escaping @Sendable () -> DiarizerBackend = { FluidDiarizerBackend() }) {
        self.store = store
        self.backendFactory = backendFactory
    }

    /// Start of a call: reload persisted fingerprints, clear the previous
    /// call's state, and warm up + enroll in the background (first-ever call
    /// downloads models; until ready, segments stay "Others" rather than
    /// blocking transcription).
    func beginCall() {
        reset()
        backendToProfile = [:]
        timeline = SpeakerTimeline()
        labeledCounts = [:]
        callOrdinals = [:]
        enrolled = false
        Task { await prepareBackend() }
    }

    private func prepareBackend() async {
        do {
            try await backend.prepare()
            enrollStoredProfiles()
        } catch {
            NSLog("Voice fingerprinting models unavailable: %@",
                  Redactor.redact(error.localizedDescription))
        }
    }

    /// Seed the backend with every NAMED same-space (neural, 256-dim)
    /// fingerprint. Legacy spectral profiles can't be enrolled — their names
    /// still attach via manual rename or the name guesser.
    ///
    /// Unnamed voices are deliberately left out. Enrolling every fingerprint
    /// the app had ever heard meant dozens of competing centroids, many built
    /// from a second or two of speech, each able to claim a stranger's voice —
    /// that is how people who were never on a call ended up in its transcript.
    /// An unnamed match also buys nothing: the end-of-call pass regroups the
    /// call from scratch anyway.
    private func enrollStoredProfiles() {
        guard !enrolled, backend.isReady else { return }
        let known = profiles.filter { $0.embedding.count >= 100 && $0.isNamed }
        backend.enroll(known.map { ($0.id.uuidString, $0.name, $0.embedding) })
        for p in known { backendToProfile[p.id.uuidString] = p.id }
        enrolled = true
    }

    /// Reload persisted fingerprints (after a rename/merge/detach) WITHOUT
    /// dropping the current call's timeline or id mappings.
    func reset() {
        profiles = (try? store.allSpeakerProfiles()) ?? []
        loaded = true
    }

    /// Diarize one system-audio chunk into speaker turns and extend the
    /// call's timeline. Call once per chunk, before labeling its segments.
    func ingest(chunk: AudioChunk) {
        guard chunk.source == .system, backend.isReady else { return }
        if !loaded { reset() }
        enrollStoredProfiles()   // models may have become ready mid-call
        let samples = ParakeetTranscriber.floatSamples(fromPCM: chunk.pcm)
        guard samples.count >= 16_000 else { return }   // <1s: nothing to segment
        guard let turns = try? backend.diarize(samples, at: chunk.t0) else { return }
        for turn in turns {
            timeline.add(speakerID: resolveProfile(for: turn),
                         start: turn.start, end: turn.end)
        }
        timeline.trim(before: chunk.t0 - 120)
    }

    /// A backend speaker id either maps to an existing profile (enrolled, or
    /// already seen this call) or mints a persistent "Speaker N" fingerprint.
    private func resolveProfile(for turn: SpeakerTurn) -> UUID {
        if let mapped = backendToProfile[turn.backendSpeakerID] { return mapped }
        let ordinal = (try? store.nextSpeakerOrdinal()) ?? (profiles.count + 1)
        let now = Date()
        let profile = SpeakerProfile(id: UUID(), name: nil, ordinal: ordinal,
                                     embedding: turn.embedding, sampleCount: 1,
                                     createdAt: now, updatedAt: now)
        profiles.append(profile)
        try? store.insertSpeakerProfile(profile)
        backendToProfile[turn.backendSpeakerID] = profile.id
        return profile.id
    }

    /// Assigns a speaker to one transcript segment from the call timeline.
    /// Returns nil to fall back to "Others".
    func label(for segment: TranscriptSegment) -> DiarizedSpeaker? {
        guard segment.source == .system else { return nil }
        if !loaded { reset() }
        guard let speakerID = timeline.speaker(overlapping: segment.t0, segment.t1),
              let profile = profiles.first(where: { $0.id == speakerID }) else { return nil }
        labeledCounts[speakerID, default: 0] += 1
        return DiarizedSpeaker(id: profile.id, label: callLabel(for: profile))
    }

    /// A named voice keeps its name; an unnamed one is numbered by when it
    /// first spoke on THIS call. The stored ordinal is a database detail —
    /// showing it made a four-person meeting read "Speaker 31, Speaker 52…".
    private func callLabel(for profile: SpeakerProfile) -> String {
        if profile.isNamed { return profile.displayLabel }
        if let existing = callOrdinals[profile.id] { return "Speaker \(existing)" }
        let next = callOrdinals.count + 1
        callOrdinals[profile.id] = next
        return "Speaker \(next)"
    }

    /// End of call: persist the backend's evolved voice centroids and the
    /// utterance counts, so the next call's enrollment matches better.
    func endCall() {
        for (backendID, embedding) in backend.finalEmbeddings() {
            guard let profileID = backendToProfile[backendID],
                  let index = profiles.firstIndex(where: { $0.id == profileID }),
                  !embedding.isEmpty else { continue }
            var p = profiles[index]
            guard p.embedding.count == embedding.count else { continue }   // never cross spaces
            p.embedding = embedding
            p.sampleCount += max(1, labeledCounts[profileID, default: 0])
            p.updatedAt = Date()
            profiles[index] = p
            try? store.updateSpeakerEmbedding(id: p.id, embedding: p.embedding,
                                              sampleCount: p.sampleCount)
        }
    }

    var speakerCount: Int { profiles.count }
}
