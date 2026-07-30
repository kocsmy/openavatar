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

    // MARK: Join link extraction (powers the pre-meeting prompt's CTA)

    func testMeetingURLPrefersTheVideoEntryPoint() throws {
        let json = try JSONValue.parse("""
        {"conferenceData": {"entryPoints": [
            {"entryPointType": "phone", "uri": "tel:+1-555-0100"},
            {"entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"}
        ]}}
        """)
        XCTAssertEqual(GoogleCalendarClient.meetingURL(of: json)?.absoluteString,
                       "https://meet.google.com/abc-defg-hij")
    }

    func testMeetingURLFallsBackToHangoutLink() throws {
        let json = try JSONValue.parse("""
        {"hangoutLink": "https://meet.google.com/xyz-abcd-efg"}
        """)
        XCTAssertEqual(GoogleCalendarClient.meetingURL(of: json)?.absoluteString,
                       "https://meet.google.com/xyz-abcd-efg")
    }

    func testMeetingURLSniffedFromLocation() throws {
        // Zoom invites usually land in location/description, not conferenceData.
        let json = try JSONValue.parse("""
        {"location": "https://acme.zoom.us/j/123456?pwd=abc"}
        """)
        XCTAssertEqual(GoogleCalendarClient.meetingURL(of: json)?.host, "acme.zoom.us")
    }

    func testNoMeetingURLForRoomOnlyEvents() throws {
        let json = try JSONValue.parse("""
        {"location": "Conference room 4B", "description": "Bring the slides https://docs.example.com/deck"}
        """)
        XCTAssertNil(GoogleCalendarClient.meetingURL(of: json))
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

/// The pre-meeting prompt window: one minute before start through ten minutes
/// after, once per event, never while recording.
final class MeetingPromptPolicyTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testQuietBeforeTheLeadWindow() {
        XCTAssertFalse(MeetingPromptPolicy.shouldPrompt(
            eventStart: start, now: start.addingTimeInterval(-120),
            isListening: false, alreadyPrompted: false))
    }

    func testPromptsOneMinuteBeforeStart() {
        XCTAssertTrue(MeetingPromptPolicy.shouldPrompt(
            eventStart: start, now: start.addingTimeInterval(-60),
            isListening: false, alreadyPrompted: false))
    }

    func testStillOffersToLateJoiners() {
        XCTAssertTrue(MeetingPromptPolicy.shouldPrompt(
            eventStart: start, now: start.addingTimeInterval(300),
            isListening: false, alreadyPrompted: false))
    }

    func testGivesUpAfterTheGraceWindow() {
        XCTAssertFalse(MeetingPromptPolicy.shouldPrompt(
            eventStart: start, now: start.addingTimeInterval(601),
            isListening: false, alreadyPrompted: false))
    }

    func testNeverPromptsWhileRecordingOrTwice() {
        XCTAssertFalse(MeetingPromptPolicy.shouldPrompt(
            eventStart: start, now: start, isListening: true, alreadyPrompted: false))
        XCTAssertFalse(MeetingPromptPolicy.shouldPrompt(
            eventStart: start, now: start, isListening: false, alreadyPrompted: true))
        XCTAssertFalse(MeetingPromptPolicy.shouldPrompt(
            eventStart: nil, now: start, isListening: false, alreadyPrompted: false))
    }
}
