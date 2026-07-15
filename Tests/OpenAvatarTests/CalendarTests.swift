import XCTest
@testable import OpenAvatar

final class CalendarTests: XCTestCase {

    private let iso = ISO8601DateFormatter()

    func testParseEventWithAttendees() throws {
        let json = try JSONValue.parse("""
        {
          "id": "evt1",
          "summary": "Sync with Acme",
          "start": {"dateTime": "2026-07-15T10:00:00Z"},
          "end": {"dateTime": "2026-07-15T10:30:00Z"},
          "attendees": [
            {"email": "me@example.com", "self": true, "organizer": true},
            {"email": "alice@acme.com", "displayName": "Alice Ng"},
            {"email": "room-3@resource.calendar.google.com", "resource": true}
          ]
        }
        """)
        let event = try XCTUnwrap(GoogleCalendarClient.parseEvent(json, iso: iso))
        XCTAssertEqual(event.title, "Sync with Acme")
        // The resource (room) is filtered out; two humans remain.
        XCTAssertEqual(event.attendees.count, 2)

        let others = event.others(excludingSelfEmail: "me@example.com")
        XCTAssertEqual(others.count, 1)
        XCTAssertEqual(others.first?.name, "Alice Ng")
    }

    func testAttendeeNameFallsBackToEmailLocalPart() {
        let a = CalendarAttendee(email: "john.smith@corp.com", displayName: nil,
                                 isSelf: false, isOrganizer: false)
        XCTAssertEqual(a.name, "John Smith")
    }

    func testSelfExcludedByFlagAndByEmail() throws {
        let json = try JSONValue.parse("""
        {
          "id": "evt2", "summary": "1:1",
          "attendees": [
            {"email": "me@example.com"},
            {"email": "boss@example.com", "displayName": "The Boss"}
          ]
        }
        """)
        let event = try XCTUnwrap(GoogleCalendarClient.parseEvent(json, iso: iso))
        // No self flag set, but self email still filters us out.
        let others = event.others(excludingSelfEmail: "me@example.com")
        XCTAssertEqual(others.map(\.name), ["The Boss"])
    }
}
