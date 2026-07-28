import Foundation

/// The call's acoustic speaker map: who was speaking when, according to the
/// diarization backend. Transcript segments get their speaker by majority
/// time-overlap against this timeline — the transcriber's utterance
/// boundaries (a whole 15s chunk for Parakeet) say nothing about speaker
/// turns, so matching text spans to acoustic turns is the only correct join.
struct SpeakerTimeline: Sendable {
    struct Turn: Equatable, Sendable {
        let speakerID: UUID
        let start: TimeInterval
        let end: TimeInterval
    }

    private(set) var turns: [Turn] = []

    mutating func add(speakerID: UUID, start: TimeInterval, end: TimeInterval) {
        guard end > start else { return }
        turns.append(Turn(speakerID: speakerID, start: start, end: end))
    }

    /// The speaker with the most speaking time inside [t0, t1]. When nothing
    /// overlaps (a turn shorter than the backend's minimum, or a boundary
    /// gap), falls back to the nearest turn within `tolerance` seconds.
    func speaker(overlapping t0: TimeInterval, _ t1: TimeInterval,
                 tolerance: TimeInterval = 1.5) -> UUID? {
        var overlap: [UUID: TimeInterval] = [:]
        for turn in turns {
            let shared = min(t1, turn.end) - max(t0, turn.start)
            if shared > 0 { overlap[turn.speakerID, default: 0] += shared }
        }
        if let best = overlap.max(by: { $0.value < $1.value }) { return best.key }

        var nearest: UUID?
        var bestGap = tolerance
        for turn in turns {
            let gap = turn.start > t1 ? turn.start - t1
                    : (t0 > turn.end ? t0 - turn.end : 0)
            if gap <= bestGap { bestGap = gap; nearest = turn.speakerID }
        }
        return nearest
    }

    /// Drop turns that ended before `cutoff` — segments are labeled as they
    /// stream in, so only the recent window is ever consulted.
    mutating func trim(before cutoff: TimeInterval) {
        turns.removeAll { $0.end < cutoff }
    }
}
