import XCTest
@testable import OpenAvatar

/// Asking questions about meetings. The LLM calls themselves aren't exercised
/// here — what's pinned is the part that decides WHAT the model gets to see,
/// because that's where a wrong answer comes from: a truncated index that
/// drops the relevant meeting, or a shortlist parsed wrongly.
final class MeetingChatTests: XCTestCase {

    private func call(_ title: String, daysAgo: Int, summary: String? = nil,
                      notes: String? = nil, userNotes: String? = nil,
                      app: String? = "Zoom") -> ContextStore.CallRecord {
        let start = Date(timeIntervalSince1970: 1_770_000_000 - Double(daysAgo) * 86_400)
        return ContextStore.CallRecord(
            id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(1800),
            app: app, summary: summary, notes: notes, userNotes: userNotes, title: title)
    }

    // MARK: Shortlist parsing

    @MainActor func testShortlistAcceptsTheShapesModelsActuallyReturn() {
        let calls = (1...8).map { call("Meeting \($0)", daysAgo: $0) }
        for reply in ["2, 5", "#2 and #5", "Meetings 2, 5", " 2\n5\n"] {
            let picked = MeetingChat.resolve(reply, against: calls)
            XCTAssertEqual(picked.map(\.id), [calls[1].id, calls[4].id], "failed on \(reply)")
        }
    }

    @MainActor func testShortlistRefusesNonsenseRatherThanReadingRandomMeetings() {
        let calls = (1...3).map { call("Meeting \($0)", daysAgo: $0) }
        XCTAssertTrue(MeetingChat.resolve("none", against: calls).isEmpty)
        XCTAssertTrue(MeetingChat.resolve("None of these are relevant.", against: calls).isEmpty)
        XCTAssertTrue(MeetingChat.resolve("42, 0, -1", against: calls).isEmpty,
                      "out-of-range numbers must not wrap around to a real meeting")
    }

    @MainActor func testShortlistIsCappedAndDeduplicated() {
        let calls = (1...20).map { call("Meeting \($0)", daysAgo: $0) }
        let picked = MeetingChat.resolve("1, 1, 2, 3, 4, 5, 6", against: calls)
        XCTAssertEqual(picked.count, MeetingChat.maxShortlist)
        XCTAssertEqual(picked.map(\.id), [calls[0].id, calls[1].id, calls[2].id, calls[3].id])
    }

    // MARK: The index

    @MainActor func testIndexIsNumberedFromOneSoTheShortlistLinesUp() {
        let calls = [call("Standup", daysAgo: 0, summary: "Sprint scope"),
                     call("Retro", daysAgo: 1)]
        let index = MeetingChat.index(of: calls, limit: 10_000)
        XCTAssertTrue(index.contains("1. "), index)
        XCTAssertTrue(index.contains("Standup"), index)
        XCTAssertTrue(index.contains("Sprint scope"), index)
        XCTAssertTrue(index.contains("2. "), index)
        // The numbering must survive the round trip.
        XCTAssertEqual(MeetingChat.resolve("2", against: calls).first?.id, calls[1].id)
    }

    @MainActor func testIndexTruncatesFromTheOldEndAndStaysWithinBudget() {
        // 400 meetings would blow any context window; the index must cap.
        let calls = (1...400).map { call("Meeting \($0)", daysAgo: $0, summary: String(repeating: "x", count: 200)) }
        let index = MeetingChat.index(of: calls, limit: 2_000)
        XCTAssertLessThanOrEqual(index.count, 2_000)
        XCTAssertTrue(index.contains("1. "), "the newest meeting is the one that must survive")
        XCTAssertFalse(index.contains("400. "))
    }

    @MainActor func testEmptyLibraryIndexIsMarkedRatherThanBlank() {
        XCTAssertEqual(MeetingChat.index(of: [], limit: 100), "(none)")
    }

    // MARK: One meeting's context

    @MainActor func testMeetingContextCarriesNotesDecisionsAndTranscript() {
        let record = call("Pricing sync", daysAgo: 0, notes: "- Ship on Friday",
                          userNotes: "ask about the discount tier")
        let segments = [
            TranscriptSegment(text: "are we shipping Friday?", t0: 0, t1: 3, source: .mic, confidence: 0.9),
            TranscriptSegment(text: "yes, assuming QA passes", t0: 3, t1: 6, source: .system,
                              confidence: 0.9, speaker: "Alice")
        ]
        let decisions = [
            Decision(callID: record.id, quote: "yes, assuming QA passes", intent: .other,
                     summary: "Ship Friday if QA passes", confidence: 0.9,
                     addressedToAssistant: false, source: .system),
            Decision(callID: record.id, quote: "drop the banner", intent: .other,
                     summary: "Dropped idea", confidence: 0.5,
                     addressedToAssistant: false, source: .system, status: .dismissed)
        ]
        let context = MeetingChat.meetingContext(call: record, segments: segments,
                                                 decisions: decisions, limit: 10_000)

        XCTAssertTrue(context.contains("Pricing sync"))
        XCTAssertTrue(context.contains("ask about the discount tier"), "the user's own notes are context too")
        XCTAssertTrue(context.contains("Ship on Friday"))
        XCTAssertTrue(context.contains("Ship Friday if QA passes"))
        XCTAssertFalse(context.contains("Dropped idea"), "dismissed actions aren't decisions")
        // Speaker labels ride along so the answer can say who said what.
        XCTAssertTrue(context.contains("[You] are we shipping Friday?"))
        XCTAssertTrue(context.contains("[Alice] yes, assuming QA passes"))
    }

    @MainActor func testLongTranscriptKeepsTheEndWhereDecisionsLive() {
        let early = Array(repeating: "small talk about the weather", count: 400)
        let segments = (early + ["so we agreed: launch on the 14th"]).enumerated().map { i, text in
            TranscriptSegment(text: text, t0: Double(i), t1: Double(i) + 1,
                              source: .system, confidence: 0.9, speaker: "Alice")
        }
        let context = MeetingChat.meetingContext(call: call("Long one", daysAgo: 0),
                                                 segments: segments, decisions: [], limit: 500)
        XCTAssertTrue(context.contains("launch on the 14th"))
        XCTAssertTrue(context.contains("(earlier part omitted)"))
    }

    @MainActor func testContextNamesMeetingsTheSameWayTheUIDoes() {
        // Reuses CallRecord.displayTitle, so an untitled Zoom call reads
        // "Zoom call" to the model exactly as it does on screen.
        let context = MeetingChat.meetingContext(call: call("", daysAgo: 0, app: "Zoom"),
                                                 segments: [], decisions: [], limit: 100)
        XCTAssertTrue(context.contains("Meeting: Zoom call"), context)
    }
}
