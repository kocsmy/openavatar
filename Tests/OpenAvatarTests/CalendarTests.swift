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

    func testCalendarListParsesAndSortsPrimaryFirst() throws {
        let json = try JSONValue.parse("""
        {
          "items": [
            {"id": "work@group.calendar.google.com", "summary": "Work"},
            {"id": "me@example.com", "summary": "Me", "primary": true},
            {"id": "family@group.calendar.google.com", "summary": "Family"}
          ]
        }
        """)
        let calendars = GoogleCalendarClient.parseCalendarList(json)
        XCTAssertEqual(calendars.map(\.name), ["Me", "Family", "Work"])
        XCTAssertTrue(calendars[0].isPrimary)
    }

    func testCalendarIDIsPercentEncodedInEventsURL() {
        let comps = GoogleCalendarClient.eventsURLComponents(
            calendarID: "work@group.calendar.google.com")
        XCTAssertTrue(comps.url!.absoluteString
            .contains("/calendars/work%40group%2Ecalendar%2Egoogle%2Ecom/events"))
    }

    // MARK: Participant summary ("Salim + 3 more")

    func testParticipantSummaryFirstNamePlusCount() {
        let event = CalendarEvent(
            id: "e1", title: "Sync", start: nil, end: nil,
            attendees: [
                CalendarAttendee(email: "me@x.com", displayName: nil, isSelf: true, isOrganizer: false),
                CalendarAttendee(email: "s@x.com", displayName: "Salim Rahal", isSelf: false, isOrganizer: false),
                CalendarAttendee(email: "a@x.com", displayName: "Ada", isSelf: false, isOrganizer: false),
                CalendarAttendee(email: "b@x.com", displayName: "Ben", isSelf: false, isOrganizer: false),
                CalendarAttendee(email: "c@x.com", displayName: "Cleo", isSelf: false, isOrganizer: false),
            ])
        XCTAssertEqual(event.participantSummary(excludingSelfEmail: "me@x.com"), "Salim + 3 more")
    }

    func testParticipantSummarySingleOtherAndNobody() {
        let one = CalendarEvent(
            id: "e2", title: "1:1", start: nil, end: nil,
            attendees: [
                CalendarAttendee(email: "me@x.com", displayName: nil, isSelf: true, isOrganizer: false),
                CalendarAttendee(email: "b@x.com", displayName: "Ben Ortiz", isSelf: false, isOrganizer: false),
            ])
        XCTAssertEqual(one.participantSummary(excludingSelfEmail: "me@x.com"), "Ben")

        let solo = CalendarEvent(id: "e3", title: "Focus", start: nil, end: nil, attendees: [])
        XCTAssertNil(solo.participantSummary(excludingSelfEmail: "me@x.com"))
    }
}
