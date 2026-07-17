import Foundation

/// Cleans streaming-transcription artifacts at ingestion, before segments are
/// stored or fed to detection. Two jobs, both pure and unit-tested:
///
/// 1. **Overlap dedupe** — audio chunks deliberately overlap by ~2 s so words
///    straddling a boundary aren't lost, which means whisper transcribes that
///    region twice: the tail of chunk k reappears at the head of chunk k+1
///    ("the exact number of IPs slash" → "the exact number of IPs slash the
///    specific IPs…"). For two segments of the same source covering the same
///    audio window that say (nearly) the same thing, only the longer one
///    survives.
/// 2. **Silence hallucinations** — whisper invents stock phrases ("Thank
///    you.", "Thanks for watching.") on silence/noise. Those land on the
///    system channel with NO diarized voice (too quiet to fingerprint), which
///    is exactly how we spot them.
enum TranscriptSanitizer {

    /// Seconds of slack when deciding two segments cover the same audio:
    /// the capture overlap (2 s) plus chunk-boundary timing jitter.
    static let overlapWindow: TimeInterval = 4.0

    /// Token overlap (relative to the shorter segment) above which two
    /// time-adjacent segments count as the same utterance. Tolerates small
    /// decode differences ("stay"/"stayed", "2 p.m."/"2pm").
    static let sameUtteranceOverlap = 0.75

    /// Whisper's classic silence hallucinations, normalized.
    static let hallucinations: Set<String> = [
        "thank you", "thank you very much", "thanks for watching",
        "thank you for watching", "please subscribe", "see you next time",
        "see you in the next video", "bye", "bye bye", "you"
    ]

    /// Filters `incoming` against itself and the most recent stored segments.
    /// Returns the incoming segments that should be kept, plus the ids of
    /// previously stored segments that turned out to be partial duplicates of
    /// a newer, fuller segment (delete them from the store and live view).
    static func reconcile(incoming: [TranscriptSegment],
                          previous: [TranscriptSegment]) -> (kept: [TranscriptSegment],
                                                             deletePrevious: Set<UUID>) {
        var kept: [TranscriptSegment] = []
        var deletePrevious: Set<UUID> = []

        for segment in incoming {
            if isHallucination(segment) { continue }

            var dropNew = false
            for prior in (previous + kept)
            where prior.source == segment.source
                && !deletePrevious.contains(prior.id)
                && segment.t0 < prior.t1 + overlapWindow {
                guard sameUtterance(prior.text, segment.text) else { continue }
                // Same utterance decoded twice — the longer reading wins.
                if tokens(segment.text).count > tokens(prior.text).count {
                    if let i = kept.firstIndex(where: { $0.id == prior.id }) {
                        kept.remove(at: i)
                    } else {
                        deletePrevious.insert(prior.id)
                    }
                } else {
                    dropNew = true
                    break
                }
            }
            if !dropNew { kept.append(segment) }
        }
        return (kept, deletePrevious)
    }

    /// A short system-channel segment that no voice fingerprint claimed
    /// (too quiet) and reads as a stock whisper filler is noise, not speech.
    /// A real "Thank you" has enough energy to diarize and is kept.
    static func isHallucination(_ segment: TranscriptSegment) -> Bool {
        segment.source == .system
            && segment.speakerID == nil
            && segment.t1 - segment.t0 < 4.0
            && hallucinations.contains(normalize(segment.text))
    }

    static func sameUtterance(_ a: String, _ b: String) -> Bool {
        let ta = Set(tokens(a)), tb = Set(tokens(b))
        guard ta.count >= 3, tb.count >= 3 else { return normalize(a) == normalize(b) }
        let overlap = Double(ta.intersection(tb).count)
        return overlap / Double(min(ta.count, tb.count)) >= sameUtteranceOverlap
    }

    static func tokens(_ s: String) -> [Substring] {
        normalize(s).split(separator: " ")
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }
}
