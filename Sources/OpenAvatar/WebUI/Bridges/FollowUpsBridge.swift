import Foundation

/// Follow-ups surface: things confirmed in a post-call review, upcoming and
/// done. Mirrors FollowUpsSettingsTab (Sources/OpenAvatar/UI/FollowUpViews.swift)
/// — same reads, same mutations, same "capture from calls" toggle.
///
/// Returns nil for any method that isn't its own — AppBridge tries the next
/// bridge. The TypeScript half of this contract lives in
/// web/src/lib/types/followups.ts.
@MainActor
final class FollowUpsBridge {
    private let app = AppState.shared
    private let settings = SettingsStore.shared

    func handle(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        case "followups.list": return list()
        case "followups.setCaptureEnabled": return setCaptureEnabled(params)
        case "followups.complete": return try complete(params)
        case "followups.snooze": return try snooze(params)
        case "followups.delete": return try deleteOne(params)
        default: return nil
        }
    }

    // MARK: Reads

    private func list() -> JSONValue {
        .object([
            "captureEnabled": .bool(settings.followUpsEnabled),
            "scheduled": .array(app.scheduledFollowUps().map(Self.encode)),
            "done": .array(app.completedFollowUps().map(Self.encode))
        ])
    }

    private static let iso = ISO8601DateFormatter()

    private static func encode(_ f: FollowUp) -> JSONValue {
        .object([
            "id": .string(f.id.uuidString),
            "callID": f.callID.map { .string($0.uuidString) } ?? .null,
            "title": .string(f.title),
            "quote": f.quote.map { .string($0) } ?? .null,
            "dueAt": .string(iso.string(from: f.dueAt)),
            "createdAt": .string(iso.string(from: f.createdAt)),
            "status": .string(f.status.rawValue)
        ])
    }

    // MARK: Writes

    /// Same toggle as SettingsStore.followUpsEnabled (spec: this tab owns it,
    /// not the General settings page), just reached through our own namespace
    /// since this page isn't a settings-window surface with the shared writer.
    private func setCaptureEnabled(_ params: JSONValue) -> JSONValue {
        settings.followUpsEnabled = params["enabled"]?.boolValue ?? settings.followUpsEnabled
        return .object([:])
    }

    /// Scheduled and done are the only two states this surface shows — look
    /// across both so "delete" still works on a completed item.
    private func find(id: UUID) -> FollowUp? {
        ((try? app.store.followUps(statuses: [.scheduled, .done])) ?? []).first { $0.id == id }
    }

    private func requireFollowUp(_ params: JSONValue, method: String) throws -> FollowUp {
        guard let idStr = params["id"]?.stringValue, let id = UUID(uuidString: idStr),
              let followUp = find(id: id) else {
            throw AppError.parsing("\(method) needs a known id")
        }
        return followUp
    }

    private func complete(_ params: JSONValue) throws -> JSONValue {
        let followUp = try requireFollowUp(params, method: "followups.complete")
        app.markFollowUpDone(followUp)
        WebEventBus.shared.emit(.followups)
        return .object([:])
    }

    private func snooze(_ params: JSONValue) throws -> JSONValue {
        let followUp = try requireFollowUp(params, method: "followups.snooze")
        let days = params["days"]?.intValue ?? 1
        app.snoozeFollowUp(followUp, byDays: days)
        WebEventBus.shared.emit(.followups)
        return .object([:])
    }

    private func deleteOne(_ params: JSONValue) throws -> JSONValue {
        let followUp = try requireFollowUp(params, method: "followups.delete")
        app.deleteFollowUp(followUp)
        WebEventBus.shared.emit(.followups)
        return .object([:])
    }
}
