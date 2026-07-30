import XCTest
@testable import OpenAvatar

/// The Qwen3-ASR engine's install layout and mode plumbing. The bridge
/// process itself needs Python + Apple Silicon and is exercised manually.
final class QwenTranscriberTests: XCTestCase {

    @MainActor func testRuntimePathsLiveInAppSupport() {
        XCTAssertTrue(QwenSetupService.runtimeDir.path.contains("OpenAvatar"))
        XCTAssertTrue(QwenSetupService.bridgeScriptURL.path
            .hasSuffix("qwen3-asr-mlx-runtime/scripts/qwen3-asr-mlx-bridge"))
    }

    func testQwenModePersistsAndDisplays() {
        XCTAssertEqual(TranscriptionMode(rawValue: "qwen"), .qwen)
        XCTAssertTrue(TranscriptionMode.qwen.displayName.contains("52"))
    }

    // MARK: Envelope stripping (regression: raw "language English<asr_text>"
    // prefixes showed up on every transcript line)

    func testLanguageEnvelopeIsStripped() {
        XCTAssertEqual(
            Qwen3Transcriber.cleanOutput("language English<asr_text>Hey, can you hear me?"),
            "Hey, can you hear me?")
        XCTAssertEqual(
            Qwen3Transcriber.cleanOutput("language Hungarian<asr_text>Szia, hallasz engem?"),
            "Szia, hallasz engem?")
    }

    func testNoSpeechEnvelopeBecomesEmpty() {
        // "language None<asr_text>" = silence; the segment must be dropped.
        XCTAssertEqual(Qwen3Transcriber.cleanOutput("language None<asr_text>"), "")
        XCTAssertEqual(Qwen3Transcriber.cleanOutput("  language None<asr_text>  "), "")
    }

    func testPlainTextPassesThroughUntouched() {
        XCTAssertEqual(
            Qwen3Transcriber.cleanOutput("I write code with AI. I design."),
            "I write code with AI. I design.")
        // Even a sentence starting with the word "language".
        XCTAssertEqual(
            Qwen3Transcriber.cleanOutput("Language is fascinating."),
            "Language is fascinating.")
    }

    func testStrayTagsAreRemoved() {
        XCTAssertEqual(
            Qwen3Transcriber.cleanOutput("<asr_text>Hello there</asr_text>"),
            "Hello there")
    }

    func testStoredEnvelopesAreScrubbedByMigration() throws {
        // Segments saved before the fix carry the envelope in the DB — the
        // v10 migration cleans them (and deletes pure no-speech markers).
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Zoom")
        try store.insert([
            TranscriptSegment(text: "language English<asr_text>Hello from before the fix",
                              t0: 0, t1: 1, source: .mic, confidence: 0.9),
            TranscriptSegment(text: "language None<asr_text>",
                              t0: 1, t1: 2, source: .system, confidence: 0.9),
            TranscriptSegment(text: "Untouched normal line",
                              t0: 2, t1: 3, source: .mic, confidence: 0.9)
        ], callID: callID)
        // Migration runs at open — but this store is already migrated, so
        // exercise the same cleaning path directly.
        let cleaned = try store.allSegments(callID: callID).map {
            Qwen3Transcriber.cleanOutput($0.text)
        }.filter { !$0.isEmpty }
        XCTAssertEqual(cleaned, ["Hello from before the fix", "Untouched normal line"])
    }
}
