import Foundation

/// One attendee of a calendar event.
struct CalendarAttendee: Identifiable, Sendable, Equatable, Hashable {
    let email: String
    let displayName: String?
    let isSelf: Bool
    let isOrganizer: Bool

    var id: String { email.isEmpty ? (displayName ?? UUID().uuidString) : email }

    /// Best human name: the display name, else the local part of the email.
    var name: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let at = email.firstIndex(of: "@") {
            return String(email[..<at]).replacingOccurrences(of: ".", with: " ").capitalized
        }
        return email
    }
}

/// A calendar event relevant to "who am I talking to right now".
struct CalendarEvent: Sendable, Equatable {
    let id: String
    let title: String
    let start: Date?
    let end: Date?
    let attendees: [CalendarAttendee]

    /// Everyone except the account owner — the people on the other end.
    func others(excludingSelfEmail selfEmail: String) -> [CalendarAttendee] {
        let selfLower = selfEmail.lowercased()
        return attendees.filter { a in
            if a.isSelf { return false }
            if !selfLower.isEmpty, a.email.lowercased() == selfLower { return false }
            return true
        }
    }
}

/// Reads the user's primary Google Calendar via the Calendar API v3.
struct GoogleCalendarClient: Sendable {
    var tokenProvider: @Sendable () async throws -> String
    var http = HTTPClient()

    /// The event happening around `now` (or the nearest one within the window),
    /// with its attendees. Returns nil when nothing is scheduled.
    func currentEvent(now: Date = Date()) async throws -> CalendarEvent? {
        let token = try await tokenProvider()
        let iso = ISO8601DateFormatter()
        let timeMin = iso.string(from: now.addingTimeInterval(-30 * 60))
        let timeMax = iso.string(from: now.addingTimeInterval(30 * 60))

        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [
            .init(name: "timeMin", value: timeMin),
            .init(name: "timeMax", value: timeMax),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "10")
        ]
        let json = try await http.getJSON(comps.url!, headers: ["Authorization": "Bearer \(token)"])
        let items = json["items"]?.arrayValue ?? []
        let events = items.compactMap { Self.parseEvent($0, iso: iso) }
        guard !events.isEmpty else { return nil }

        // Prefer an event in progress; else the soonest upcoming; else the last.
        if let ongoing = events.first(where: { ev in
            guard let s = ev.start, let e = ev.end else { return false }
            return s <= now && now <= e
        }) { return ongoing }
        if let upcoming = events.first(where: { ($0.start ?? .distantPast) >= now }) { return upcoming }
        return events.last
    }

    static func parseEvent(_ item: JSONValue, iso: ISO8601DateFormatter) -> CalendarEvent? {
        guard let id = item["id"]?.stringValue else { return nil }
        let title = item["summary"]?.stringValue ?? "(untitled event)"
        let start = date(from: item["start"], iso: iso)
        let end = date(from: item["end"], iso: iso)
        let attendees = (item["attendees"]?.arrayValue ?? []).compactMap { a -> CalendarAttendee? in
            let email = a["email"]?.stringValue ?? ""
            // Skip rooms/resources.
            if a["resource"]?.boolValue == true { return nil }
            guard !email.isEmpty || a["displayName"]?.stringValue != nil else { return nil }
            return CalendarAttendee(
                email: email,
                displayName: a["displayName"]?.stringValue,
                isSelf: a["self"]?.boolValue ?? false,
                isOrganizer: a["organizer"]?.boolValue ?? false)
        }
        return CalendarEvent(id: id, title: title, start: start, end: end, attendees: attendees)
    }

    private static func date(from node: JSONValue?, iso: ISO8601DateFormatter) -> Date? {
        guard let node else { return nil }
        if let dt = node["dateTime"]?.stringValue {
            return iso.date(from: dt) ?? ISO8601DateFormatter.withFractional.date(from: dt)
        }
        if let d = node["date"]?.stringValue {   // all-day event
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
            return df.date(from: d)
        }
        return nil
    }
}

extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
