import Foundation
import SpeakerKit

/// Diarization of a finished recording, all at once.
///
/// The streaming path (SpeakerDiarizer) has to decide who is speaking from a
/// 15-second window with no knowledge of the rest of the call, and it pays for
/// that: published benchmarks put streaming 5-10 DER points behind batch, and
/// the errors it makes are over-clustering — one voice split across several
/// ids. This runs after the call instead, over the whole recording, where the
/// clusterer can see every utterance a person made before deciding how many
/// people there were.
protocol OfflineDiarizerBackend: Sendable {
    /// `maxSpeakers` caps the cluster count (the calendar roster, when we
    /// have one). Turns come back on the recording's clock.
    func diarize(fileURL: URL, maxSpeakers: Int?) async throws -> [SpeakerTurn]
}

/// Argmax SpeakerKit: pyannote v4 ("community-1") segmentation + embedding +
/// VBx clustering as CoreML. A model generation ahead of the streaming path's
/// pipeline, and the batch mode is the mode these models are benchmarked in —
/// this pass is what decides how many people the finished call really had.
actor SpeakerKitOfflineDiarizerBackend: OfflineDiarizerBackend {
    private var kit: SpeakerKit?

    func diarize(fileURL: URL, maxSpeakers: Int?) async throws -> [SpeakerTurn] {
        let samples = try Self.samples(fromWAV: fileURL)
        guard !samples.isEmpty else { return [] }
        let kit = try await loadKit()
        var result = try await kit.diarize(audioArray: samples,
                                           options: PyannoteDiarizationOptions())
        // numberOfSpeakers forces an EXACT count (no-show invitees would make
        // the clusterer invent voices), so the first pass always auto-detects.
        // The roster only vetoes an overshoot: more voices than people invited
        // means over-splitting, and the re-run makes the model distribute the
        // audio over a plausible head-count instead.
        if let maxSpeakers, result.speakerCount > maxSpeakers {
            result = try await kit.diarize(
                audioArray: samples,
                options: PyannoteDiarizationOptions(numberOfSpeakers: maxSpeakers))
        }
        return Self.turns(from: result)
    }

    /// Models download from Hugging Face on first use and are cached; the
    /// loaded kit is reused across calls.
    private func loadKit() async throws -> SpeakerKit {
        if let kit { return kit }
        let fresh = try await SpeakerKit(PyannoteConfig(modelDownloadConfig: nil,
                                                        download: true, verbose: false))
        kit = fresh
        return fresh
    }

    // MARK: Pure helpers (pinned by tests)

    /// Call recordings are canonical 16 kHz mono 16-bit WAV (WAVEncoder): a
    /// 44-byte header, then PCM — SpeakerKit's exact input after Int16→Float.
    static func samples(fromWAV url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 44 else { return [] }
        return ParakeetTranscriber.floatSamples(fromPCM: data.dropFirst(44))
    }

    /// SpeakerKit segments → our turns. Every turn carries its speaker's
    /// cluster centroid; spans SpeakerKit could not attribute to one voice
    /// (overlapped speech, no match) are dropped and read as "Others".
    static func turns(from result: DiarizationResult) -> [SpeakerTurn] {
        result.segments.compactMap { segment in
            guard let id = segment.speaker.speakerId else { return nil }
            return SpeakerTurn(backendSpeakerID: String(id),
                               embedding: result.speakerCentroidEmbeddings[id] ?? [],
                               start: TimeInterval(segment.startTime),
                               end: TimeInterval(segment.endTime))
        }
    }
}
