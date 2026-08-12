import Foundation
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

/// Meetings surface: the transcript library and a single meeting's detail.
/// Mirrors MeetingsTab / MeetingDetailView (Sources/OpenAvatar/UI/TranscriptViews.swift)
/// — same reads, same mutations, same wording. Formatting (plain-text and
/// markdown export) reuses TranscriptFormatter directly so the web export is
/// byte-for-byte what the native app would have written.
///
/// Returns nil for any method that isn't its own — AppBridge tries the next
/// bridge. The TypeScript half of this contract lives in
/// web/src/lib/types/meetings.ts.
@MainActor
final class MeetingsBridge {
    private let app = AppState.shared
    private let settings = SettingsStore.shared
    private static let iso = ISO8601DateFormatter()

    func handle(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        case "meetings.list": return list()
        case "meetings.detail": return try detail(params)
        case "meetings.delete": return try delete(params)
        case "meetings.renameSpeaker": return try renameSpeaker(params)
        case "meetings.mergeSpeaker": return try mergeSpeaker(params)
        case "meetings.detachSpeaker": return try detachSpeaker(params)
        case "meetings.sweepStrayVoices": return sweepStrayVoices()
        case "meetings.prepareDecision": return try prepareDecision(params)
        case "meetings.markDecisionDone": return try markDecisionDone(params)
        case "meetings.dismissDecision": return try dismissDecision(params)
        case "meetings.confirmFollowUp": return try confirmFollowUp(params)
        case "meetings.dismissFollowUp": return try dismissFollowUpAction(params)
        case "meetings.copyTranscript": return try copyTranscript(params)
        case "meetings.exportMarkdown": return try exportMarkdown(params)
        default: return nil
        }
    }

    // MARK: List

    /// Every call, newest first — the web page groups it by day itself
    /// (pure display logic, no need to round-trip that grouping).
    private func list() -> JSONValue {
        let calls = (try? app.store.listCalls()) ?? []
        return .object(["meetings": .array(calls.map(Self.encodeSummary))])
    }

    private static func encodeSummary(_ call: ContextStore.CallRecord) -> JSONValue {
        .object([
            "id": .string(call.id.uuidString),
            "startedAt": .string(iso.string(from: call.startedAt)),
            "endedAt": call.endedAt.map { .string(iso.string(from: $0)) } ?? .null,
            "app": call.app.map { .string($0) } ?? .null,
            "title": call.title.map { .string($0) } ?? .null,
            "summary": call.summary.map { .string($0) } ?? .null
        ])
    }

    // MARK: Detail

    /// listCalls() + filter, same as MeetingsTab's own `calls.first(where:)` —
    /// there's no single-row fetch on the store, and 200 rows is cheap.
    private func requireCall(_ params: JSONValue) throws -> ContextStore.CallRecord {
        guard let idStr = params["callID"]?.stringValue, let id = UUID(uuidString: idStr),
              let call = (try? app.store.listCalls())?.first(where: { $0.id == id }) else {
            throw AppError.parsing("Unknown meeting")
        }
        return call
    }

    private func detail(_ params: JSONValue) throws -> JSONValue {
        let call = try requireCall(params)
        let segments = (try? app.store.segments(callID: call.id)) ?? []
        let speakers = (try? app.store.speakerProfiles(callID: call.id)) ?? []
        let allSpeakers = (try? app.store.allSpeakerProfiles()) ?? []
        let decisions = (try? app.store.decisions(callID: call.id)) ?? []
        let followUps = (try? app.store.followUps(callID: call.id)) ?? []

        // The freshest notes: right after a call ends, consolidation publishes
        // them before the store record's own snapshot catches up (matches
        // MeetingDetailView.resolvedNotes).
        let liveNotes: JSONValue
        if call.id == app.currentCallID, let live = app.reviewCallNotes, !live.isEmpty {
            liveNotes = .string(live)
        } else {
            liveNotes = .null
        }

        var callJSON = Self.encodeSummary(call).objectValue ?? [:]
        callJSON["notes"] = call.notes.map { .string($0) } ?? .null
        callJSON["userNotes"] = call.userNotes.map { .string($0) } ?? .null

        return .object([
            "call": .object(callJSON),
            "liveNotes": liveNotes,
            "isConsolidating": .bool(app.isConsolidating),
            "isListening": .bool(app.isListening),
            "segments": .array(segments.map(Self.encodeSegment)),
            "speakers": .array(speakers.map(Self.encodeSpeaker)),
            "allSpeakers": .array(allSpeakers.map(Self.encodeSpeaker)),
            "decisions": .array(decisions.map(Self.encodeDecision)),
            "followUps": .array(followUps.map(Self.encodeFollowUp))
        ])
    }

    private static func encodeSegment(_ s: TranscriptSegment) -> JSONValue {
        .object([
            "id": .string(s.id.uuidString),
            "t0": .number(s.t0),
            "source": .string(s.source.rawValue),
            "speaker": s.speaker.map { .string($0) } ?? .null,
            "speakerID": s.speakerID.map { .string($0) } ?? .null,
            "text": .string(s.text)
        ])
    }

    private static func encodeSpeaker(_ p: SpeakerProfile) -> JSONValue {
        .object([
            "id": .string(p.id.uuidString),
            "name": p.name.map { .string($0) } ?? .null,
            "ordinal": .number(Double(p.ordinal)),
            "sampleCount": .number(Double(p.sampleCount))
        ])
    }

    private static func encodeDecision(_ d: Decision) -> JSONValue {
        .object([
            "id": .string(d.id.uuidString),
            "summary": .string(d.summary),
            "quote": .string(d.quote),
            "status": .string(d.status.rawValue)
        ])
    }

    private static func encodeFollowUp(_ f: FollowUp) -> JSONValue {
        .object([
            "id": .string(f.id.uuidString),
            "title": .string(f.title),
            "dueAt": .string(iso.string(from: f.dueAt)),
            "status": .string(f.status.rawValue)
        ])
    }

    // MARK: Meeting & speaker mutations
    //
    // None of these touch AppState's own @Published properties for a past
    // meeting (rename/merge/detach only patch `liveSegments` when the voice
    // is heard on the *current* call), so unlike the settings surfaces we
    // can't rely on WebEventBus's throttled "state" emit — push "meetings"
    // ourselves once the store write lands, same as FollowUpsBridge does.

    private func delete(_ params: JSONValue) throws -> JSONValue {
        let call = try requireCall(params)
        app.deleteMeeting(call.id)
        WebEventBus.shared.emit(.meetings)
        return .object([:])
    }

    private func renameSpeaker(_ params: JSONValue) throws -> JSONValue {
        guard let id = params["speakerID"]?.stringValue else {
            throw AppError.parsing("meetings.renameSpeaker needs a speakerID")
        }
        app.renameSpeaker(id: id, to: params["name"]?.stringValue)
        WebEventBus.shared.emit(.meetings)
        return .object([:])
    }

    private func mergeSpeaker(_ params: JSONValue) throws -> JSONValue {
        guard let source = params["sourceID"]?.stringValue,
              let target = params["targetID"]?.stringValue else {
            throw AppError.parsing("meetings.mergeSpeaker needs sourceID and targetID")
        }
        app.mergeSpeaker(sourceID: source, into: target)
        WebEventBus.shared.emit(.meetings)
        return .object([:])
    }

    private func detachSpeaker(_ params: JSONValue) throws -> JSONValue {
        guard let callIDStr = params["callID"]?.stringValue, let callID = UUID(uuidString: callIDStr),
              let speakerID = params["speakerID"]?.stringValue else {
            throw AppError.parsing("meetings.detachSpeaker needs callID and speakerID")
        }
        _ = app.detachSpeaker(callID: callID, from: speakerID)
        WebEventBus.shared.emit(.meetings)
        return .object([:])
    }

    private func sweepStrayVoices() -> JSONValue {
        let folded = app.sweepStrayVoices()
        if folded > 0 { WebEventBus.shared.emit(.meetings) }
        return .object(["foldedCount": .number(Double(folded))])
    }

    // MARK: Decisions & follow-ups
    //
    // The store only supports fetch-by-call, not fetch-by-id, so mutations
    // carry both ids and look the record up the same way MeetingDetailView's
    // in-memory `decisions`/`followUps` arrays already did.

    private func findDecision(_ params: JSONValue) throws -> Decision {
        guard let callIDStr = params["callID"]?.stringValue, let callID = UUID(uuidString: callIDStr),
              let decisionIDStr = params["decisionID"]?.stringValue,
              let decisionID = UUID(uuidString: decisionIDStr),
              let decision = (try? app.store.decisions(callID: callID))?
                .first(where: { $0.id == decisionID }) else {
            throw AppError.parsing("Unknown decision")
        }
        return decision
    }

    /// Generates the plan/preview for a passive-mode decision. Status stays
    /// "detected" here too — the preview surfaces in the approval flow, not
    /// on this page (matches the native Prepare button exactly).
    private func prepareDecision(_ params: JSONValue) throws -> JSONValue {
        app.prepare(try findDecision(params))
        return .object([:])
    }

    private func markDecisionDone(_ params: JSONValue) throws -> JSONValue {
        app.markDone(try findDecision(params))
        WebEventBus.shared.emit(.meetings)
        return .object([:])
    }

    private func dismissDecision(_ params: JSONValue) throws -> JSONValue {
        guard let reason = DismissReason(rawValue: params["reason"]?.stringValue ?? "") else {
            throw AppError.parsing("meetings.dismissDecision needs a known reason")
        }
        app.dismiss(try findDecision(params), reason: reason)
        WebEventBus.shared.emit(.meetings)
        return .object([:])
    }

    private func findFollowUp(_ params: JSONValue) throws -> FollowUp {
        guard let callIDStr = params["callID"]?.stringValue, let callID = UUID(uuidString: callIDStr),
              let followUpIDStr = params["followUpID"]?.stringValue,
              let followUpID = UUID(uuidString: followUpIDStr),
              let followUp = (try? app.store.followUps(callID: callID))?
                .first(where: { $0.id == followUpID }) else {
            throw AppError.parsing("Unknown follow-up")
        }
        return followUp
    }

    private func confirmFollowUp(_ params: JSONValue) throws -> JSONValue {
        app.confirmFollowUp(try findFollowUp(params))
        WebEventBus.shared.emit(.meetings)
        return .object([:])
    }

    private func dismissFollowUpAction(_ params: JSONValue) throws -> JSONValue {
        app.dismissFollowUp(try findFollowUp(params))
        WebEventBus.shared.emit(.meetings)
        return .object([:])
    }

    // MARK: Export
    //
    // Both reuse TranscriptFormatter so the web port writes exactly what the
    // native menu items would have.

    private func copyTranscript(_ params: JSONValue) throws -> JSONValue {
        let call = try requireCall(params)
        let segments = (try? app.store.segments(callID: call.id)) ?? []
#if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            TranscriptFormatter.plainText(segments, callStart: call.startedAt),
            forType: .string)
#endif
        return .object(["message": .string("Copied")])
    }

    private func exportMarkdown(_ params: JSONValue) throws -> JSONValue {
        let call = try requireCall(params)
        let segments = (try? app.store.segments(callID: call.id)) ?? []
#if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "transcript-\(call.startedAt.formatted(.iso8601.year().month().day())).md"
        guard panel.runModal() == .OK, let url = panel.url else {
            return .object(["message": .string("")])   // cancelled — nothing to report
        }
        do {
            let markdown = TranscriptFormatter.markdown(call: call, segments: segments)
            try Data(markdown.utf8).write(to: url)
            return .object(["message": .string("Exported to \(url.lastPathComponent)")])
        } catch {
            return .object(["message": .string("Export failed: \(Redactor.redact(error.localizedDescription))")])
        }
#else
        return .object(["message": .string("Export needs macOS")])
#endif
    }
}
