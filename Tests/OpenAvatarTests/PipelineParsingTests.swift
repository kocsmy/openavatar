import XCTest
@testable import OpenAvatar

final class PipelineParsingTests: XCTestCase {

    // MARK: Decision parsing (spec §4.4)

    private var window: [TranscriptSegment] {
        [TranscriptSegment(text: "Let's create a ticket for the login bug",
                           t0: 0, t1: 3, source: .mic, confidence: 0.9),
         TranscriptSegment(text: "Sounds good, and merge the header PR",
                           t0: 3, t1: 6, source: .system, confidence: 0.9)]
    }

    func testParseDecisionsMapsFieldsAndAttributesSource() throws {
        let args = try JSONValue.parse("""
        {"decisions":[
          {"quote":"Let's create a ticket for the login bug","intent":"create_ticket",
           "summary":"Create login bug ticket","confidence":0.85,"addressed_to_assistant":false},
          {"quote":"merge the header PR","intent":"merge_pr",
           "summary":"Merge header PR","confidence":0.7,"addressed_to_assistant":false,
           "assignee_hint":"sam"}
        ]}
        """)
        let decisions = DecisionDetector.parseDecisions(args, callID: UUID(), window: window)
        XCTAssertEqual(decisions.count, 2)

        XCTAssertEqual(decisions[0].intent, .createTicket)
        XCTAssertEqual(decisions[0].source, .mic)          // matched to the mic segment
        XCTAssertEqual(decisions[0].confidence, 0.85, accuracy: 0.001)

        XCTAssertEqual(decisions[1].intent, .mergePR)
        XCTAssertEqual(decisions[1].source, .system)        // spoken by another participant
        XCTAssertEqual(decisions[1].assigneeHint, "sam")
    }

    func testParseDecisionsToleratesUnknownIntent() throws {
        let args = try JSONValue.parse("""
        {"decisions":[{"quote":"q","intent":"do_magic","summary":"s",
                       "confidence":0.5,"addressed_to_assistant":true}]}
        """)
        let decisions = DecisionDetector.parseDecisions(args, callID: nil, window: [])
        XCTAssertEqual(decisions.first?.intent, .other)
        XCTAssertEqual(decisions.first?.addressedToAssistant, true)
        // Unmatched quotes default to .system — the conservative choice for §5.6.
        XCTAssertEqual(decisions.first?.source, .system)
    }

    func testQuoteNormalizationAndSimilarity() {
        let a = DecisionDetector.normalize("Let's SHIP it, now!")
        let b = DecisionDetector.normalize("lets ship it now")
        XCTAssertEqual(a, b)
        XCTAssertTrue(DecisionDetector.similar("create the login ticket", "login ticket"))
        XCTAssertFalse(DecisionDetector.similar("", "x"))
    }

    // MARK: Whisper JSON parsing (spec §4.2)

    func testWhisperSegmentParsing() throws {
        let json = try JSONValue.parse("""
        {"transcription":[
          {"offsets":{"from":0,"to":1500},"text":" Hello world"},
          {"offsets":{"from":1500,"to":2000},"text":" [BLANK_AUDIO]"}]}
        """)
        let chunk = AudioChunk(pcm: Data(), source: .mic, t0: 100, t1: 115)
        let segments = WhisperLocalTranscriber.parseSegments(json, chunk: chunk)
        XCTAssertEqual(segments.count, 1) // hallucination artifact filtered
        XCTAssertEqual(segments[0].text, "Hello world")
        XCTAssertEqual(segments[0].t0, 100.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].t1, 101.5, accuracy: 0.001)
        XCTAssertEqual(segments[0].source, .mic)
    }

    // MARK: WAV encoding

    func testWAVHeader() {
        let pcm = Data(repeating: 0, count: 3200) // 0.1 s of 16 kHz 16-bit mono
        let wav = WAVEncoder.wavData(fromPCM: pcm)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        // Sample rate at offset 24, little endian.
        let rate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: rate), 16_000)
        XCTAssertEqual(wav.count, 44 + pcm.count)
    }

    // MARK: Metrics (spec §6)

    func testMetricsRatesAndCSV() throws {
        let store = try ContextStore(inMemory: true)
        let metrics = MetricsRecorder(store: store)
        try metrics.bump("decisions_detected", by: 4)
        try metrics.bump("auto_approved_no_edit", by: 3)
        try metrics.bump("executed", by: 3)
        try metrics.bump("reverted", by: 1)
        try metrics.setBaseline(minutes: 45)

        let rows = try metrics.fetchAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].autoApproveNoEditRate, 0.75, accuracy: 0.001)
        XCTAssertEqual(rows[0].revertRate, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(rows[0].adminMinutesBaseline, 45)

        let csv = try metrics.exportCSV()
        XCTAssertTrue(csv.hasPrefix("date,decisions_detected"))
        XCTAssertTrue(csv.contains(",4,3,"))
    }

    func testMetricsBumpRejectsUnknownColumns() throws {
        let store = try ContextStore(inMemory: true)
        // Must be a silent no-op, never SQL on an attacker-controlled column.
        try MetricsRecorder(store: store).bump("date; DROP TABLE metrics_daily")
        XCTAssertEqual(try MetricsRecorder(store: store).fetchAll().count, 0)
    }

    // MARK: Context store round-trips

    func testDecisionAndExportRoundTrip() throws {
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "zoom.us")
        let decision = Decision(callID: callID, quote: "ship it", intent: .mergePR,
                                summary: "Merge the PR", assigneeHint: nil,
                                confidence: 0.9, addressedToAssistant: true, source: .mic)
        try store.insert(decision)
        try store.updateDecisionStatus(decision.id, status: .dismissed,
                                       dismissReason: .wrongIntent)
        try store.endCall(callID, summary: "test")

        let export = try store.exportAllJSON()
        let json = try JSONValue.parse(export)
        XCTAssertEqual(json["decisions"]?.arrayValue?.count, 1)
        XCTAssertEqual(json["decisions"]?[0]?["status"]?.stringValue, "dismissed")
        XCTAssertEqual(json["decisions"]?[0]?["dismiss_reason"]?.stringValue, "wrong_intent")
        XCTAssertEqual(json["calls"]?.arrayValue?.count, 1)

        try store.deleteAllData()
        let empty = try JSONValue.parse(try store.exportAllJSON())
        XCTAssertEqual(empty["decisions"]?.arrayValue?.count, 0)
    }
}
