import XCTest
@testable import OpenAvatar

final class FollowUpTests: XCTestCase {

    func testParseDateAcceptsIsoAndDateOnly() {
        // Full ISO datetime.
        XCTAssertNotNil(FollowUpExtractor.parseDate("2026-07-16T14:30:00Z"))
        // Date-only defaults to 09:00 local.
        let dayOnly = FollowUpExtractor.parseDate("2026-07-16")
        let comps = Calendar.current.dateComponents([.hour, .minute], from: try! XCTUnwrap(dayOnly))
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
        // Garbage → nil.
        XCTAssertNil(FollowUpExtractor.parseDate("sometime soon"))
    }

    func testParseKeepsFutureItemsAndResolvesFields() throws {
        let callStart = ISO8601DateFormatter().date(from: "2026-07-15T10:00:00Z")!
        let args = try JSONValue.parse("""
        {"followups": [
          {"title": "Check the JTM script IDs", "due": "2026-07-16T09:00:00Z",
           "quote": "tomorrow we need to check the script IDs"},
          {"title": "Ancient task", "due": "2020-01-01T09:00:00Z", "quote": "last year"},
          {"title": "", "due": "2026-07-20T09:00:00Z"}
        ]}
        """)
        let callID = UUID()
        let followUps = FollowUpExtractor.parse(args, callID: callID, callStart: callStart)

        // Past item dropped; empty-title item dropped; one valid remains.
        XCTAssertEqual(followUps.count, 1)
        let f = try XCTUnwrap(followUps.first)
        XCTAssertEqual(f.title, "Check the JTM script IDs")
        XCTAssertEqual(f.quote, "tomorrow we need to check the script IDs")
        XCTAssertEqual(f.callID, callID)
        XCTAssertEqual(f.status, .suggested)
        XCTAssertGreaterThan(f.dueAt, callStart)
    }

    func testStoreCrudAndStatusFilter() throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let a = FollowUp(callID: UUID(), title: "Ping Ben", quote: nil,
                         dueAt: now.addingTimeInterval(3600), status: .scheduled)
        let b = FollowUp(callID: nil, title: "Draft note", quote: nil,
                         dueAt: now.addingTimeInterval(7200), status: .suggested)
        try store.insertFollowUp(a)
        try store.insertFollowUp(b)

        XCTAssertEqual(try store.followUps(statuses: [.scheduled]).map(\.title), ["Ping Ben"])
        XCTAssertEqual(try store.followUps(statuses: [.suggested]).count, 1)

        // Confirm b → scheduled; now two scheduled, soonest first.
        try store.updateFollowUpStatus(id: b.id, status: .scheduled)
        XCTAssertEqual(try store.followUps(statuses: [.scheduled]).map(\.title), ["Ping Ben", "Draft note"])

        // Snooze a past b's due, mark a done, delete b.
        try store.updateFollowUpStatus(id: a.id, status: .done)
        XCTAssertEqual(try store.followUps(statuses: [.done]).map(\.title), ["Ping Ben"])
        try store.deleteFollowUp(id: b.id)
        XCTAssertTrue(try store.followUps(statuses: [.scheduled, .suggested]).isEmpty)
    }
}
