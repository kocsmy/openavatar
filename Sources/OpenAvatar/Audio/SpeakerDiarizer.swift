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

/// The engine behind the LIVE diarization pass. Production uses FluidAudio's
/// streaming pipeline (pyannote-style segmentation + WeSpeaker embeddings +
/// clustering with a running per-call speaker map); tests inject a scripted
/// fake. Deliberately per-call: the backend starts every call empty and is
/// never seeded with stored voices — recognition against the database is the
/// feature that kept putting absent people on calls, and it is gone.
protocol DiarizerBackend {
    var isReady: Bool { get }
    func prepare() async throws
    /// Full diarization of one audio window; `time` is the window's absolute
    /// call-relative start, so returned turns are on the call clock.
    func diarize(_ samples: [Float], at time: TimeInterval) throws -> [SpeakerTurn]
}

/// FluidAudio's streaming diarization pipeline. Finds acoustic speaker turns
/// inside each audio window; its SpeakerManager keeps ids consistent across
/// sequential windows of the same call.
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

    func diarize(_ samples: [Float], at time: TimeInterval) throws -> [SpeakerTurn] {
        guard let manager else { throw AppError.notConfigured("Diarization models not loaded") }
        return try manager.performCompleteDiarization(samples, atTime: time).segments.map {
            SpeakerTurn(backendSpeakerID: $0.speakerId, embedding: $0.embedding,
                        start: TimeInterval($0.startTimeSeconds),
                        end: TimeInterval($0.endTimeSeconds))
        }
    }
}

/// On-device per-voice diarization for the system-audio ("Others") channel,
/// live during the call.
///
/// Each audio chunk is diarized into timed speaker turns (see
/// DiarizerBackend); transcript segments then take the speaker who did most
/// of the talking in their time range (SpeakerTimeline). Every voice is a
/// fresh per-call "Speaker N" the user can rename; nothing is matched against
/// voices from earlier calls. The labels here are provisional — the
/// end-of-call pass (CallSpeakerFinalizer) re-clusters the whole recording
/// and rewrites them. The mic channel is always "You" and never diarized.
actor SpeakerDiarizer {
    private let store: ContextStore
    private let backendFactory: @Sendable () -> DiarizerBackend
    private lazy var backend: DiarizerBackend = backendFactory()

    /// Voice fingerprints, loaded from the store (for name lookups after a
    /// rename — never for acoustic matching).
    private var profiles: [SpeakerProfile] = []
    private var loaded = false

    // Per-call working state (cleared by beginCall).
    private var backendToProfile: [String: UUID] = [:]
    private var timeline = SpeakerTimeline()
    /// "Speaker N" numbering scoped to this call, in first-heard order.
    private var callOrdinals: [UUID: Int] = [:]

    init(store: ContextStore = .shared,
         backendFactory: @escaping @Sendable () -> DiarizerBackend = { FluidDiarizerBackend() }) {
        self.store = store
        self.backendFactory = backendFactory
    }

    /// Start of a call: clear the previous call's state and warm up in the
    /// background (first-ever call downloads models; until ready, segments
    /// stay "Others" rather than blocking transcription).
    func beginCall() {
        reset()
        backendToProfile = [:]
        timeline = SpeakerTimeline()
        callOrdinals = [:]
        Task { await prepareBackend() }
    }

    private func prepareBackend() async {
        do {
            try await backend.prepare()
        } catch {
            NSLog("Voice fingerprinting models unavailable: %@",
                  Redactor.redact(error.localizedDescription))
        }
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
        let samples = ParakeetTranscriber.floatSamples(fromPCM: chunk.pcm)
        guard samples.count >= 16_000 else { return }   // <1s: nothing to segment
        guard let turns = try? backend.diarize(samples, at: chunk.t0) else { return }
        for turn in turns {
            timeline.add(speakerID: resolveProfile(for: turn),
                         start: turn.start, end: turn.end)
        }
        timeline.trim(before: chunk.t0 - 120)
    }

    /// A backend speaker id either maps to a voice already seen this call or
    /// mints a fresh "Speaker N" fingerprint for it.
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

    var speakerCount: Int { profiles.count }
}
