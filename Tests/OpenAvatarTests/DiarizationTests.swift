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

    private func makeDiarizer() -> SpeakerDiarizer {
        // Isolated in-memory store so fingerprints don't leak between tests.
        let store = try! ContextStore(inMemory: true)
        return SpeakerDiarizer(store: store)
    }

    func testMicChannelNeverDiarized() async {
        let diarizer = makeDiarizer()
        let micChunk = AudioChunk(pcm: Data(count: 32_000), source: .mic, t0: 0, t1: 1)
        let seg = TranscriptSegment(text: "hi", t0: 0, t1: 1, source: .mic, confidence: 0.9)
        let hit = await diarizer.label(for: seg, in: micChunk)
        XCTAssertNil(hit)   // → falls back to "You"
        XCTAssertEqual(seg.speakerLabel, "You")
    }

    func testSpeakerLabelPrefersDiarizedSpeaker() {
        var seg = TranscriptSegment(text: "x", t0: 0, t1: 1, source: .system, confidence: 0.9)
        XCTAssertEqual(seg.speakerLabel, "Others")
        seg.speaker = "Speaker 3"
        XCTAssertEqual(seg.speakerLabel, "Speaker 3")
    }

#if canImport(Accelerate)
    // New profiles require ≥2 s of audio, so creation-path tests use 2.5 s.

    func testDistinctPitchesGetDistinctSpeakers() async {
        let diarizer = makeDiarizer()
        // A low voice and a clearly higher voice.
        let (lowChunk, lowSeg) = chunk(pitch: 110, seconds: 2.5)   // ~male
        let (highChunk, highSeg) = chunk(pitch: 240, seconds: 2.5) // ~female
        let a = await diarizer.label(for: lowSeg, in: lowChunk)
        let b = await diarizer.label(for: highSeg, in: highChunk)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a?.id, b?.id, "Distinct pitches should not collapse into one speaker")
    }

    func testSameVoiceStaysOneSpeaker() async {
        let diarizer = makeDiarizer()
        let (c1, s1) = chunk(pitch: 130, seconds: 2.5)
        let (c2, s2) = chunk(pitch: 132, seconds: 2.5)   // essentially the same voice
        let a = await diarizer.label(for: s1, in: c1)
        let b = await diarizer.label(for: s2, in: c2)
        XCTAssertEqual(a?.id, b?.id, "The same voice should keep one fingerprint")
        let count = await diarizer.speakerCount
        XCTAssertEqual(count, 1)
    }

    /// The over-splitting fix: a short clip that matches nothing must never
    /// mint a permanent "Speaker N" — the stray one-utterance speakers were
    /// the top fingerprinting complaint on 1:1 calls.
    func testShortUtteranceNeverMintsANewSpeaker() async {
        let diarizer = makeDiarizer()

        // A short clip with no established voices → no profile at all.
        let (shortFirst, segFirst) = chunk(pitch: 200, seconds: 0.6)
        _ = await diarizer.label(for: segFirst, in: shortFirst)
        var count = await diarizer.speakerCount
        XCTAssertEqual(count, 0, "A sub-2s clip must not create a fingerprint")

        // Establish a real voice, then throw a short off-voice clip at it.
        let (long, segLong) = chunk(pitch: 130, seconds: 2.5)
        _ = await diarizer.label(for: segLong, in: long)
        let (shortOdd, segOdd) = chunk(pitch: 260, seconds: 0.6)
        _ = await diarizer.label(for: segOdd, in: shortOdd)
        count = await diarizer.speakerCount
        XCTAssertEqual(count, 1, "Short clips may match or stay Others, never mint")
    }

    /// A named voice keeps its name when it reappears in a later call.
    func testNamePersistsAcrossCalls() async throws {
        let store = try ContextStore(inMemory: true)
        let diarizer = SpeakerDiarizer(store: store)

        // First call: a voice is heard and the user names it.
        let (c1, s1) = chunk(pitch: 150, seconds: 2.5)
        let first = await diarizer.label(for: s1, in: c1)
        let id = try XCTUnwrap(first?.id)
        try store.renameSpeaker(id: id, to: "Alice")

        // Second call (fresh diarizer, same store): the same voice is recognized.
        let diarizer2 = SpeakerDiarizer(store: store)
        await diarizer2.beginCall()
        let (c2, s2) = chunk(pitch: 151, seconds: 2.5)
        let second = await diarizer2.label(for: s2, in: c2)
        XCTAssertEqual(second?.id, id, "Same voice should match its stored fingerprint")
        XCTAssertEqual(second?.label, "Alice", "The assigned name should carry across calls")
    }
#endif
}
