import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Call notes surface: live transcript, speakers, and in-call decisions.
///
/// Returns nil for any method that isn't its own — AppBridge tries the next
/// bridge. The TypeScript half of this contract lives in
/// web/src/lib/types/call.ts.
///
/// Once a call ends, this window hands over to the meeting detail — the same
/// takeover CallNotesWindowView did, since that review is where the detected
/// actions get approved. The page renders the Meetings surface's own detail
/// component against `ended.callID`, so the review exists in exactly one
/// place and this bridge never reimplements it.
@MainActor
final class CallBridge {
    private let app = AppState.shared
    private let settings = SettingsStore.shared

    func handle(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        case "call.state": return state()
        case "call.transcript": return transcript()
        case "call.saveNotes": return try saveNotes(params)
        case "call.stop":
            app.stopListening()
            return .object([:])
        case "call.renameSpeaker": return try renameSpeaker(params)
        case "call.copyTranscript": return copyTranscript()
        default: return nil
        }
    }

    // MARK: State

    /// Mirrors CallNotesWindowView's own mode computation: an event preview
    /// only holds while no call is running, and an ended call only takes over
    /// once listening has stopped and no preview claimed the window first.
    private func state() -> JSONValue {
        let previewEvent = app.isListening ? nil : app.previewEvent

        var mode = "live"
        var eventJSON: JSONValue = .null
        var endedJSON: JSONValue = .null
        var notes = ""
        var targetID: JSONValue = .null

        if let event = previewEvent {
            mode = "event"
            eventJSON = encode(event: event)
            notes = (try? app.store.eventNotes(eventID: event.id)) ?? ""
            targetID = .string(event.id)
        } else if let record = endedRecord() {
            mode = "ended"
            endedJSON = encode(ended: record)
        } else if let callID = app.currentCallID {
            notes = (try? app.store.callUserNotes(callID)) ?? ""
            targetID = .string(callID.uuidString)
        }

        return .object([
            "mode": .string(mode),
            "isListening": .bool(app.isListening),
            "assistantName": .string(settings.assistantName),
            "autoStartOnCall": .bool(settings.autoStartOnCall),
            "notes": .string(notes),
            "targetId": targetID,
            "event": eventJSON,
            "ended": endedJSON
        ])
    }

    /// The just-ended call's record, once present — same lookup as
    /// CallNotesWindowView.refreshEndedCall.
    private func endedRecord() -> ContextStore.CallRecord? {
        guard !app.isListening, let callID = app.currentCallID else { return nil }
        return (try? app.store.listCalls(limit: 200))?.first { $0.id == callID }
    }

    private func encode(event: CalendarEvent) -> JSONValue {
        let iso = ISO8601DateFormatter()
        return .object([
            "id": .string(event.id),
            "title": .string(event.title),
            "start": event.start.map { .string(iso.string(from: $0)) } ?? .null,
            "end": event.end.map { .string(iso.string(from: $0)) } ?? .null,
            "conferenceService": event.conferenceService.map(JSONValue.string) ?? .null,
            "participantSummary": event.participantSummary(excludingSelfEmail: settings.calendarSelfEmail)
                .map(JSONValue.string) ?? .null
        ])
    }

    /// The freshest notes available, same priority as MeetingDetailView's
    /// resolvedNotes: consolidation's live draft first, then the stored record.
    private func encode(ended call: ContextStore.CallRecord) -> JSONValue {
        let iso = ISO8601DateFormatter()
        var notes = call.notes
        if call.id == app.currentCallID, let live = app.reviewCallNotes, !live.isEmpty {
            notes = live
        }
        return .object([
            "callID": .string(call.id.uuidString),
            "title": .string(call.displayTitle),
            "startedAt": .string(iso.string(from: call.startedAt)),
            "endedAt": call.endedAt.map { .string(iso.string(from: $0)) } ?? .null,
            "appName": call.app.map(JSONValue.string) ?? .null,
            "notes": notes.map(JSONValue.string) ?? .null,
            "summary": call.summary.map(JSONValue.string) ?? .null,
            "isConsolidating": .bool(app.isConsolidating)
        ])
    }

    // MARK: Notes autosave

    /// Same target resolution as CallNotesWindowView.scheduleSave: the preview
    /// event wins while no call is running, otherwise the live/just-ended call.
    private func saveNotes(_ params: JSONValue) throws -> JSONValue {
        guard let text = params["text"]?.stringValue else {
            throw AppError.parsing("call.saveNotes needs text")
        }
        if !app.isListening, let event = app.previewEvent {
            try app.store.updateEventNotes(eventID: event.id, title: event.title,
                                           start: event.start, notes: text)
        } else if let callID = app.currentCallID {
            try app.store.updateCallUserNotes(callID, text: text)
        }
        return .object([:])
    }

    // MARK: Transcript

    private func transcript() -> JSONValue {
        let speakers = app.callSpeakers.map { speaker in
            JSONValue.object([
                "id": .string(speaker.id),
                "label": .string(speaker.label),
                "segmentCount": .number(Double(speaker.segmentCount))
            ])
        }
        let attendees = app.callAttendees.map { attendee in
            JSONValue.object(["id": .string(attendee.id), "name": .string(attendee.name)])
        }
        let segments = app.liveSegments.map { segment in
            JSONValue.object([
                "id": .string(segment.id.uuidString),
                "t0": .number(segment.t0),
                "t1": .number(segment.t1),
                "source": .string(segment.source.rawValue),
                "speaker": segment.speaker.map(JSONValue.string) ?? .null,
                "speakerId": segment.speakerID.map(JSONValue.string) ?? .null,
                "speakerLabel": .string(segment.speakerLabel),
                "text": .string(segment.text)
            ])
        }
        return .object([
            "isListening": .bool(app.isListening),
            "eventTitle": (app.currentEvent?.title).map(JSONValue.string) ?? .null,
            "speakers": .array(speakers),
            "attendees": .array(attendees),
            "segments": .array(segments)
        ])
    }

    /// Renaming sticks to the voice fingerprint (via AppState.renameSpeaker),
    /// so it relabels the whole transcript immediately and carries to future
    /// calls — same as the native roster row and the attendee quick-assign.
    private func renameSpeaker(_ params: JSONValue) throws -> JSONValue {
        guard let id = params["id"]?.stringValue else {
            throw AppError.parsing("call.renameSpeaker needs id")
        }
        app.renameSpeaker(id: id, to: params["name"]?.stringValue ?? "")
        return .object([:])
    }

    private func copyTranscript() -> JSONValue {
#if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TranscriptFormatter.plainText(app.liveSegments), forType: .string)
#endif
        return .object([:])
    }
}
