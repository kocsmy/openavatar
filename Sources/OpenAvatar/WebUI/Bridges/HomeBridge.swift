import Foundation

/// Home surface: what the app is doing right now, and the shortcuts to change it.
///
/// Returns nil for any method that isn't its own — AppBridge tries the next
/// bridge. The TypeScript half of this contract lives in
/// web/src/lib/types/home.ts.
@MainActor
final class HomeBridge {
    private let app = AppState.shared
    private let settings = SettingsStore.shared
    private let iso = ISO8601DateFormatter()

    func handle(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        case "home.snapshot": return snapshot()
        case "home.refresh": app.refreshUpcomingEvents(); return .object([:])
        case "home.startListening": app.startListening(); return .object([:])
        case "home.stopListening": app.stopListening(); return .object([:])
        case "home.openEventNotes": return try openEventNotes(params)
        default: return nil
        }
    }

    private func snapshot() -> JSONValue {
        .object([
            "isListening": .bool(app.isListening),
            "autoStartOnCall": .bool(settings.autoStartOnCall),
            "calendarEnabled": .bool(settings.calendarEnabled),
            "events": .array(app.upcomingEvents.map(eventJSON))
        ])
    }

    /// Same fields the native ForEach/eventRow reads off CalendarEvent — the
    /// "who's there" summary and the [start, end]-contains-now check are
    /// computed here so the page stays a dumb renderer.
    private func eventJSON(_ event: CalendarEvent) -> JSONValue {
        let now = Date()
        let isNow: Bool
        if let start = event.start, let end = event.end {
            isNow = start <= now && now <= end
        } else {
            isNow = false
        }
        return .object([
            "id": .string(event.id),
            "title": .string(event.title),
            "start": event.start.map { .string(iso.string(from: $0)) } ?? .null,
            "end": event.end.map { .string(iso.string(from: $0)) } ?? .null,
            "conferenceService": event.conferenceService.map(JSONValue.string) ?? .null,
            "participantSummary": event.participantSummary(excludingSelfEmail: settings.calendarSelfEmail)
                .map(JSONValue.string) ?? .null,
            "isNow": .bool(isNow)
        ])
    }

    /// The event must still be in the current upcoming list — it's the only
    /// place the web page ever saw an id, same as the native ForEach binding.
    private func openEventNotes(_ params: JSONValue) throws -> JSONValue {
        guard let id = params["eventID"]?.stringValue,
              let event = app.upcomingEvents.first(where: { $0.id == id }) else {
            throw AppError.parsing("home.openEventNotes needs a known eventID")
        }
        app.openEventNotes(event)
        return .object([:])
    }
}
