import XCTest
@testable import OpenAvatar

/// Per-voice diarization: separates distinct voices in the system channel,
/// keeps the mic channel as "You".
final class DiarizationTests: XCTestCase {

    /// Synthesizes ~1s of a voiced tone at a given pitch as 16 kHz Int16 PCM
    /// wrapped in an AudioChunk on the system channel.
    private func chunk(pitch: Double, seconds: Double = 1.0) -> (AudioChunk, TranscriptSegment) {
        let rate = 16_000.0
        let n = Int(rate * seconds)
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            let t = Double(i) / rate
            // Fundamental + a couple of harmonics → a voice-like spectrum.
            let s = 0.5 * sin(2 * .pi * pitch * t)
                  + 0.3 * sin(2 * .pi * pitch * 2 * t)
                  + 0.2 * sin(2 * .pi * pitch * 3 * t)
            let v = Int16(max(-1, min(1, s)) * 20000)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let audio = AudioChunk(pcm: pcm, source: .system, t0: 0, t1: seconds)
        let segment = TranscriptSegment(text: "hello", t0: 0, t1: seconds,
                                        source: .system, confidence: 0.9)
        return (audio, segment)
    }

    func testMicChannelNeverDiarized() async {
        let diarizer = SpeakerDiarizer()
        let micChunk = AudioChunk(pcm: Data(count: 32_000), source: .mic, t0: 0, t1: 1)
        let seg = TranscriptSegment(text: "hi", t0: 0, t1: 1, source: .mic, confidence: 0.9)
        let label = await diarizer.label(for: seg, in: micChunk)
        XCTAssertNil(label)   // → falls back to "You"
        XCTAssertEqual(seg.speakerLabel, "You")
    }

    func testSpeakerLabelPrefersDiarizedSpeaker() {
        var seg = TranscriptSegment(text: "x", t0: 0, t1: 1, source: .system, confidence: 0.9)
        XCTAssertEqual(seg.speakerLabel, "Others")
        seg.speaker = "Speaker 3"
        XCTAssertEqual(seg.speakerLabel, "Speaker 3")
    }

#if canImport(Accelerate)
    func testDistinctPitchesGetDistinctSpeakers() async {
        let diarizer = SpeakerDiarizer()
        // A low voice and a clearly higher voice.
        let (lowChunk, lowSeg) = chunk(pitch: 110)   // ~male
        let (highChunk, highSeg) = chunk(pitch: 240) // ~female
        let a = await diarizer.label(for: lowSeg, in: lowChunk)
        let b = await diarizer.label(for: highSeg, in: highChunk)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b, "Distinct pitches should not collapse into one speaker")
    }

    func testSameVoiceStaysOneSpeaker() async {
        let diarizer = SpeakerDiarizer()
        let (c1, s1) = chunk(pitch: 130)
        let (c2, s2) = chunk(pitch: 132)   // essentially the same voice
        let a = await diarizer.label(for: s1, in: c1)
        let b = await diarizer.label(for: s2, in: c2)
        XCTAssertEqual(a, b, "The same voice should keep one label")
        let count = await diarizer.speakerCount
        XCTAssertEqual(count, 1)
    }
#endif
}
