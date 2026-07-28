import XCTest
@testable import OpenAvatar

/// The Meetings library: call titles from calendar events, pre-call notes
/// written against an upcoming event, and the per-call action roll-up.
final class MeetingTests: XCTestCase {

    func testCallTitleRoundTripAndDisplayFallbacks() throws {
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Zoom")

        // Before any calendar context: named after the hosting app.
        var record = try XCTUnwrap(store.listCalls(limit: 1).first)
        XCTAssertEqual(record.displayTitle, "Zoom call")

        try store.updateCallTitle(callID, title: "Web Engineering - Sync")
        record = try XCTUnwrap(store.listCalls(limit: 1).first)
        XCTAssertEqual(record.title, "Web Engineering - Sync")
        XCTAssertEqual(record.displayTitle, "Web Engineering - Sync")
    }

    func testDisplayTitleDoesNotDoubleTheWordCall() throws {
        let store = try ContextStore(inMemory: true)
        _ = try store.startCall(app: "Safari call")
        let record = try XCTUnwrap(store.listCalls(limit: 1).first)
        XCTAssertEqual(record.displayTitle, "Safari call")
    }

    func testEventNotesUpsertRoundTrip() throws {
        let store = try ContextStore(inMemory: true)
        XCTAssertEqual(try store.eventNotes(eventID: "evt1"), "")

        try store.updateEventNotes(eventID: "evt1", title: "Sync", start: Date(),
                                   notes: "- ask about pricing")
        XCTAssertEqual(try store.eventNotes(eventID: "evt1"), "- ask about pricing")

        // Second save replaces, not duplicates.
        try store.updateEventNotes(eventID: "evt1", title: "Sync", start: Date(),
                                   notes: "- ask about pricing\n- and timeline")
        XCTAssertEqual(try store.eventNotes(eventID: "evt1"),
                       "- ask about pricing\n- and timeline")
    }

    func testFollowUpsByCallOnlyReturnsThatCall() throws {
        let store = try ContextStore(inMemory: true)
        let callA = try store.startCall(app: "Zoom")
        let callB = try store.startCall(app: "Meet")
        try store.insertFollowUp(FollowUp(callID: callA, title: "Check script IDs",
                                          quote: nil, dueAt: Date()))
        try store.insertFollowUp(FollowUp(callID: callB, title: "Send deck",
                                          quote: nil, dueAt: Date()))

        let forA = try store.followUps(callID: callA)
        XCTAssertEqual(forA.map(\.title), ["Check script IDs"])
    }

    func testDecisionsAreScopedToTheirCall() throws {
        // The end-of-call digest is built from store.decisions(callID:) —
        // regression: it used to read a shared in-memory array that a
        // back-to-back next session could already own, mixing two calls'
        // items into both digests.
        let store = try ContextStore(inMemory: true)
        let callA = try store.startCall(app: "Zoom")
        let callB = try store.startCall(app: "Meet")
        let a = Decision(callID: callA, quote: "q1", intent: .createTicket,
                         summary: "Fix tracking", assigneeHint: nil, confidence: 0.8,
                         addressedToAssistant: false, source: .mic)
        let b = Decision(callID: callB, quote: "q2", intent: .other,
                         summary: "Ship roadmap", assigneeHint: nil, confidence: 0.8,
                         addressedToAssistant: false, source: .mic)
        try store.insert(a)
        try store.insert(b)

        XCTAssertEqual((try store.decisions(callID: callA)).map(\.summary), ["Fix tracking"])
        XCTAssertEqual((try store.decisions(callID: callB)).map(\.summary), ["Ship roadmap"])
    }

    func testDigestSplitsIntoScannableBullets() {
        // The digest is decision summaries joined with "; " — the summary pane
        // must never show it as one wall of text.
        let digest = "Tighten up design fixes; Review demo/tickets and report gaps; Add back the opt-out page (removed after Termly migration).;  ; Monitor cookie-consent impact."
        XCTAssertEqual(MeetingFormat.digestBullets(digest), [
            "Tighten up design fixes",
            "Review demo/tickets and report gaps",
            "Add back the opt-out page (removed after Termly migration)",
            "Monitor cookie-consent impact",
        ])
    }

    func testConsolidatorNotesLeadWithASummarySection() {
        // The meeting page's Summary tab renders these notes; the contract is
        // that they open with "## Summary" before the topic sections.
        XCTAssertTrue(MemoryConsolidator.systemPrompt.contains("## Summary"))
    }
}
