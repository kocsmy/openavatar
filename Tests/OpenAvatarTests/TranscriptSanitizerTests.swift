import XCTest
@testable import OpenAvatar

/// Streaming-artifact cleanup, driven by real defects found when comparing a
/// call's transcript against Zoom's: ~92 chunk-overlap duplicate lines and a
/// phantom "Others" speaker full of hallucinated "Thank you." fillers.
final class TranscriptSanitizerTests: XCTestCase {

    private func segment(_ text: String, t0: TimeInterval, t1: TimeInterval,
                         source: AudioSource = .system,
                         speakerID: String? = "voice-1") -> TranscriptSegment {
        TranscriptSegment(text: text, t0: t0, t1: t1, source: source,
                          confidence: 0.9, speaker: nil, speakerID: speakerID)
    }

    // MARK: Chunk-overlap dedupe

    func testPartialTailReplacedByFullerRedecode() {
        // Chunk k ends mid-sentence; chunk k+1 re-transcribes the overlap and
        // completes it. The partial must be deleted, the full one kept.
        let partial = segment("the exact number of IPs slash", t0: 13, t1: 15)
        let full = segment("the exact number of IPs slash the specific IPs we own", t0: 13.5, t1: 18)

        let result = TranscriptSanitizer.reconcile(incoming: [full], previous: [partial])
        XCTAssertEqual(result.kept.map(\.id), [full.id])
        XCTAssertEqual(result.deletePrevious, [partial.id])
    }

    func testShorterRedecodeOfSameUtteranceIsDropped() {
        // The reverse: the re-decode is worse/shorter — keep what we have.
        let full = segment("So we stayed there for like from 2 p.m. to like 8 p.m.", t0: 13, t1: 16)
        let stub = segment("So we stayed there for like from 2 p.m.", t0: 14, t1: 16)

        let result = TranscriptSanitizer.reconcile(incoming: [stub], previous: [full])
        XCTAssertTrue(result.kept.isEmpty)
        XCTAssertTrue(result.deletePrevious.isEmpty)
    }

    func testExactDuplicateWithinWindowDropped() {
        let a = segment("let's ship the pricing fix on Monday", t0: 10, t1: 12)
        let b = segment("Let's ship the pricing fix on Monday.", t0: 11, t1: 13)
        let result = TranscriptSanitizer.reconcile(incoming: [b], previous: [a])
        XCTAssertTrue(result.kept.isEmpty)
    }

    func testSameSentenceLaterInCallIsKept() {
        // Outside the overlap window it's a genuine repetition, not an artifact.
        let a = segment("sounds good to me", t0: 10, t1: 11)
        let b = segment("sounds good to me", t0: 60, t1: 61)
        let result = TranscriptSanitizer.reconcile(incoming: [b], previous: [a])
        XCTAssertEqual(result.kept.map(\.id), [b.id])
    }

    func testDifferentSourcesNeverDeduped() {
        // "You" echoing the other side's words is legitimate content.
        let theirs = segment("we need the proxy settings", t0: 10, t1: 12, source: .system)
        let mine = segment("we need the proxy settings", t0: 11, t1: 13, source: .mic,
                           speakerID: nil)
        let result = TranscriptSanitizer.reconcile(incoming: [mine], previous: [theirs])
        XCTAssertEqual(result.kept.map(\.id), [mine.id])
    }

    func testDistinctAdjacentSpeechUntouched() {
        let a = segment("what about the migration timeline", t0: 10, t1: 12)
        let b = segment("I think we land it next sprint", t0: 12, t1: 14)
        let result = TranscriptSanitizer.reconcile(incoming: [b], previous: [a])
        XCTAssertEqual(result.kept.map(\.id), [b.id])
        XCTAssertTrue(result.deletePrevious.isEmpty)
    }

    // MARK: Silence hallucinations

    func testUndiarizedThankYouOnSystemChannelDropped() {
        // Too quiet to fingerprint + stock filler text = whisper hallucination.
        let ghost = segment("Thank you.", t0: 20, t1: 21, speakerID: nil)
        let result = TranscriptSanitizer.reconcile(incoming: [ghost], previous: [])
        XCTAssertTrue(result.kept.isEmpty)
    }

    func testDiarizedThankYouKept() {
        // A real person audibly saying thanks fingerprints fine — keep it.
        let real = segment("Thank you.", t0: 20, t1: 21, speakerID: "voice-1")
        let result = TranscriptSanitizer.reconcile(incoming: [real], previous: [])
        XCTAssertEqual(result.kept.map(\.id), [real.id])
    }

    func testMicThankYouKept() {
        // The mic channel has no diarization; never treat it as hallucination.
        let mine = segment("Thank you.", t0: 20, t1: 21, source: .mic, speakerID: nil)
        let result = TranscriptSanitizer.reconcile(incoming: [mine], previous: [])
        XCTAssertEqual(result.kept.map(\.id), [mine.id])
    }

    func testSubstantiveUndiarizedSpeechKept() {
        // Only the stock filler list is suspect — real sentences stay even
        // when the voice couldn't be fingerprinted.
        let speech = segment("the invoice went out this morning", t0: 20, t1: 22, speakerID: nil)
        let result = TranscriptSanitizer.reconcile(incoming: [speech], previous: [])
        XCTAssertEqual(result.kept.map(\.id), [speech.id])
    }
}
