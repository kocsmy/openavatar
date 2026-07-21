import Foundation
import FluidAudio

/// Local neural transcription via NVIDIA's Parakeet TDT v3 (CoreML on the
/// Apple Neural Engine), through the FluidAudio Swift package. Compared to
/// whisper.cpp: several times faster, more accurate on its 25 supported
/// languages (including English and Hungarian), auto-detects language, and
/// needs no external binary — but no custom-vocabulary biasing, and languages
/// outside its set fall back to nonsense (use Whisper for those).
///
/// The actor is long-lived (models take seconds to load, so loading per chunk
/// like the stateless whisper-cli shell-out would be unusable). First use
/// downloads ~600 MB of CoreML models to ~/.cache/fluidaudio; afterwards it's
/// fully offline.
actor ParakeetTranscriber: Transcriber {
    static let shared = ParakeetTranscriber()

    private var manager: AsrManager?
    /// Streaming decoder state per audio channel — it carries linguistic
    /// context (last token, LSTM state) across chunk boundaries, so keeping
    /// one per source means the mic and system streams don't corrupt each
    /// other's context.
    private var decoderStates: [AudioSource: TdtDecoderState] = [:]

    var isReady: Bool { manager != nil }

    /// Whether the ~600 MB model download already happened on this Mac —
    /// checked on disk, so the settings UI can show "ready" after an app
    /// restart instead of offering the download again. (Loading the models
    /// into memory still happens lazily on first use.)
    static var modelsOnDisk: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    /// Download (first time) and load the models. Idempotent; concurrent
    /// callers wait on the actor.
    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
        decoderStates = [:]
    }

    func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSegment] {
        try await prepare()
        guard let manager else {
            throw AppError.notConfigured("Parakeet models are not loaded")
        }
        let samples = Self.floatSamples(fromPCM: chunk.pcm)
        guard !samples.isEmpty else { return [] }

        var state = try decoderStates[chunk.source] ?? TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        decoderStates[chunk.source] = state

        let text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !text.isEmpty, !WhisperLocalTranscriber.isNoise(text) else { return [] }
        return [TranscriptSegment(text: text, t0: chunk.t0, t1: chunk.t1,
                                  source: chunk.source, confidence: 0.9)]
    }

    /// Mono 16 kHz Int16 PCM → normalized Float samples (Parakeet's input).
    static func floatSamples(fromPCM pcm: Data) -> [Float] {
        let count = pcm.count / MemoryLayout<Int16>.size
        guard count > 0 else { return [] }
        return pcm.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count { out[i] = Float(ints[i]) / 32768.0 }
            return out
        }
    }
}
