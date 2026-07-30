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
struct CalendarEvent: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date?
    let end: Date?
    let attendees: [CalendarAttendee]
    /// Conferencing service of the event ("Google Meet", "Zoom", …) when the
    /// event carries a meeting link — used to label browser-hosted calls.
    var conferenceService: String? = nil
    /// The link to actually join the call — powers the pre-meeting prompt's
    /// "Join" button.
    var meetingURL: URL? = nil

    /// Everyone except the account owner — the people on the other end.
    func others(excludingSelfEmail selfEmail: String) -> [CalendarAttendee] {
        let selfLower = selfEmail.lowercased()
        return attendees.filter { a in
            if a.isSelf { return false }
            if !selfLower.isEmpty, a.email.lowercased() == selfLower { return false }
            return true
        }
    }

    /// Compact who's-there line: "Salim + 3 more" (first name of the first
    /// other participant, then a count). Nil when nobody else is invited.
    func participantSummary(excludingSelfEmail selfEmail: String) -> String? {
        let others = others(excludingSelfEmail: selfEmail)
        guard let first = others.first else { return nil }
        let firstName = first.name.split(separator: " ").first.map(String.init) ?? first.name
        let rest = others.count - 1
        return rest > 0 ? "\(firstName) + \(rest) more" : firstName
    }
}

/// One calendar the account can read — for the "which calendar" picker.
struct CalendarInfo: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let isPrimary: Bool
}

/// Reads the user's chosen Google Calendar via the Calendar API v3.
struct GoogleCalendarClient: Sendable {
    var tokenProvider: @Sendable () async throws -> String
    var http = HTTPClient()

    /// Events endpoint for a calendar id (ids contain '@' and must be
    /// percent-encoded as a single path component).
    static func eventsURLComponents(calendarID: String) -> URLComponents {
        let encoded = calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? calendarID
        return URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encoded)/events")!
    }

    /// Every calendar on the account, primary first — for the settings picker.
    func listCalendars() async throws -> [CalendarInfo] {
        let token = try await tokenProvider()
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=50")!
        let json = try await http.getJSON(url, headers: ["Authorization": "Bearer \(token)"])
        return Self.parseCalendarList(json)
    }

    static func parseCalendarList(_ json: JSONValue) -> [CalendarInfo] {
        (json["items"]?.arrayValue ?? [])
            .compactMap { item -> CalendarInfo? in
                guard let id = item["id"]?.stringValue else { return nil }
                return CalendarInfo(id: id,
                                    name: item["summary"]?.stringValue ?? id,
                                    isPrimary: item["primary"]?.boolValue ?? false)
            }
            .sorted { a, b in
                if a.isPrimary != b.isPrimary { return a.isPrimary }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// The event happening around `now` (or the nearest one within the window),
    /// with its attendees. Returns nil when nothing is scheduled.
    func currentEvent(calendarID: String = "primary", now: Date = Date()) async throws -> CalendarEvent? {
        let token = try await tokenProvider()
        let iso = ISO8601DateFormatter()
        let timeMin = iso.string(from: now.addingTimeInterval(-30 * 60))
        let timeMax = iso.string(from: now.addingTimeInterval(30 * 60))

        var comps = Self.eventsURLComponents(calendarID: calendarID)
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

    /// Events over the next `days` (skipping ones already over), for the
    /// "Coming up" home view. All-day events are excluded — they're not calls.
    func upcomingEvents(calendarID: String = "primary", days: Int = 7,
                        now: Date = Date()) async throws -> [CalendarEvent] {
        let token = try await tokenProvider()
        let iso = ISO8601DateFormatter()
        var comps = Self.eventsURLComponents(calendarID: calendarID)
        comps.queryItems = [
            .init(name: "timeMin", value: iso.string(from: now)),
            .init(name: "timeMax", value: iso.string(from: now.addingTimeInterval(Double(days) * 86_400))),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "30")
        ]
        let json = try await http.getJSON(comps.url!, headers: ["Authorization": "Bearer \(token)"])
        return (json["items"]?.arrayValue ?? [])
            .filter { $0["start"]?["dateTime"] != nil }   // has a time = not all-day
            .compactMap { Self.parseEvent($0, iso: iso) }
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
        return CalendarEvent(id: id, title: title, start: start, end: end,
                             attendees: attendees,
                             conferenceService: conferenceService(of: item),
                             meetingURL: meetingURL(of: item))
    }

    /// The joinable link for the event: Google's explicit video entry point,
    /// then the hangout link, then a meeting URL sniffed out of the location
    /// or description (how Zoom/Teams invites usually arrive).
    static func meetingURL(of item: JSONValue) -> URL? {
        for entry in item["conferenceData"]?["entryPoints"]?.arrayValue ?? []
        where entry["entryPointType"]?.stringValue == "video" {
            if let uri = entry["uri"]?.stringValue, let url = URL(string: uri) {
                return url
            }
        }
        if let link = item["hangoutLink"]?.stringValue, let url = URL(string: link) {
            return url
        }
        let meetingDomains = ["meet.google.com", "zoom.us", "teams.microsoft.com",
                              "teams.live.com", "webex.com", "whereby.com", "around.co"]
        for text in [item["location"]?.stringValue,
                     item["description"]?.stringValue].compactMap({ $0 }) {
            for raw in text.split(whereSeparator: { " \n\t<>\"'".contains($0) }) {
                let token = String(raw)
                guard token.hasPrefix("http"),
                      meetingDomains.contains(where: token.contains),
                      let url = URL(string: token) else { continue }
                return url
            }
        }
        return nil
    }

    /// Names the event's conferencing service. Google events state it
    /// explicitly (conferenceSolution.name, e.g. "Google Meet"); otherwise
    /// sniff well-known meeting domains from the link, location, or notes.
    static func conferenceService(of item: JSONValue) -> String? {
        if let solution = item["conferenceData"]?["conferenceSolution"]?["name"]?.stringValue,
           !solution.isEmpty {
            return solution
        }
        var haystack = [item["hangoutLink"]?.stringValue,
                        item["location"]?.stringValue,
                        item["description"]?.stringValue]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        for entry in item["conferenceData"]?["entryPoints"]?.arrayValue ?? [] {
            haystack += " " + (entry["uri"]?.stringValue ?? "").lowercased()
        }
        let domains: [(String, String)] = [
            ("meet.google.com", "Google Meet"),
            ("zoom.us", "Zoom"),
            ("teams.microsoft.com", "Microsoft Teams"),
            ("teams.live.com", "Microsoft Teams"),
            ("webex.com", "Webex"),
            ("whereby.com", "Whereby"),
            ("around.co", "Around")
        ]
        return domains.first { haystack.contains($0.0) }?.1
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
