import Foundation
import FluidAudio

/// A voice-embedding backend for speaker fingerprinting: turns an utterance's
/// PCM into a vector, together with the cosine-DISTANCE thresholds calibrated
/// for that vector space (0 = identical voice; larger = more different).
/// Thresholds live on the embedder because they are meaningless outside their
/// space — the neural space separates speakers at ~0.7 distance, the old
/// spectral space at ~0.16.
protocol VoiceEmbedder {
    /// One-time setup (e.g. model download/load). Cheap when already prepared.
    func prepare() async throws
    var isReady: Bool { get }
    func embedding(for samples: [Float]) -> [Float]?

    var joinDistance: Float { get }          // join an existing voice
    var namedJoinDistance: Float { get }     // join a NAMED voice not yet heard this call
    var activeRejoinDistance: Float { get }  // rejoin a voice established this call
    var continuityDistance: Float { get }    // glue short clips to the previous speaker
    var strayFoldDistance: Float { get }     // end-of-call: fold stray into dominant
    var namedAdoptDistance: Float { get }    // end-of-call: dominant adopts stored name
}

/// Cosine distance (1 − cosine similarity). Mismatched dimensions — e.g. a
/// legacy 25-dim spectral fingerprint against a 256-dim neural one — are
/// "infinitely far": they can never match, so old profiles are simply
/// grandfathered out of matching rather than corrupting it.
func voiceCosineDistance(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    let denom = na.squareRoot() * nb.squareRoot()
    guard denom > 0 else { return .greatestFiniteMagnitude }
    return 1 - dot / denom
}

/// FluidAudio's speaker-embedding model (pyannote-family segmentation +
/// WeSpeaker 256-dim embeddings as CoreML) — the proven, benchmarked voice
/// fingerprint that replaces the hand-rolled spectral one. Models download
/// once (~tens of MB) to ~/.cache/fluidaudio and run fully on-device.
final class NeuralVoiceEmbedder: VoiceEmbedder {
    private var manager: DiarizerManager?

    var isReady: Bool { manager != nil }

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await DiarizerModels.downloadIfNeeded()
        let m = DiarizerManager()
        m.initialize(models: models)
        manager = m
    }

    func embedding(for samples: [Float]) -> [Float]? {
        guard let manager,
              let embedding = try? manager.extractSpeakerEmbedding(from: samples),
              manager.validateEmbedding(embedding) else { return nil }
        return embedding
    }

    // Anchored on FluidAudio's own clustering threshold (0.7 distance =
    // "same speaker"): stricter for adopting a NAME, looser for re-joining
    // a voice already established on this call.
    let joinDistance: Float = 0.70
    let namedJoinDistance: Float = 0.60
    let activeRejoinDistance: Float = 0.80
    let continuityDistance: Float = 0.90
    let strayFoldDistance: Float = 0.80
    let namedAdoptDistance: Float = 0.65
}

/// The original lightweight FFT log-mel + pitch fingerprint. Kept as the
/// deterministic backend for unit tests and as the offline fallback if the
/// neural models cannot be downloaded/loaded. Thresholds are the historical
/// similarity values (0.84 join etc.) expressed as distance.
final class SpectralVoiceEmbedder: VoiceEmbedder {
    private let extractor = EmbeddingExtractor()

    var isReady: Bool { true }
    func prepare() {}

    func embedding(for samples: [Float]) -> [Float]? {
        extractor.embedding(samples)
    }

    let joinDistance: Float = 0.16
    let namedJoinDistance: Float = 0.12
    let activeRejoinDistance: Float = 0.22
    let continuityDistance: Float = 0.30
    let strayFoldDistance: Float = 0.25
    let namedAdoptDistance: Float = 0.14
}
