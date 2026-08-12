import Foundation
import FluidAudio

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
    /// `maxSpeakers` bounds the cluster count (the calendar roster, when we
    /// have one). Turns come back on the recording's clock.
    func diarize(fileURL: URL, maxSpeakers: Int?) async throws -> [SpeakerTurn]
}

/// FluidAudio's offline pipeline: powerset segmentation + WeSpeaker embeddings
/// + PLDA/VBx clustering — the same models the streaming path uses, run in the
/// mode they were designed for.
struct FluidOfflineDiarizerBackend: OfflineDiarizerBackend {
    func diarize(fileURL: URL, maxSpeakers: Int?) async throws -> [SpeakerTurn] {
        var config = OfflineDiarizerConfig.default
        if let maxSpeakers {
            // A ceiling, never an exact count: invitees who never speak must
            // not force the clusterer to invent voices for them. numSpeakers
            // would do exactly that, so it stays unset.
            config.clustering.maxSpeakers = max(2, maxSpeakers)
        }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let result = try await manager.process(fileURL)
        return result.segments.map {
            SpeakerTurn(backendSpeakerID: $0.speakerId, embedding: $0.embedding,
                        start: TimeInterval($0.startTimeSeconds),
                        end: TimeInterval($0.endTimeSeconds))
        }
    }
}
