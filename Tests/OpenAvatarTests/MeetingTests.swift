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

    func testConsolidatorNotesLeadWithASummarySection() {
        // The meeting page's Summary tab renders these notes; the contract is
        // that they open with "## Summary" before the topic sections.
        XCTAssertTrue(MemoryConsolidator.systemPrompt.contains("## Summary"))
    }
}
