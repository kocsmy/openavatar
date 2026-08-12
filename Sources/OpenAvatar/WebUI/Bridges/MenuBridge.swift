import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Menu-bar surface: the popover's state, decisions, and controls.
///
/// The popover only ever sends ids across the bridge; every action here looks
/// the real model object up in AppState before calling into it, the same way
/// MenuBarView.swift used to bind straight to `@EnvironmentObject var app`.
///
/// Returns nil for any method that isn't its own — AppBridge tries the next
/// bridge. The TypeScript half of this contract lives in
/// web/src/lib/types/menu.ts.
@MainActor
final class MenuBridge {
    private let app = AppState.shared
    private let settings = SettingsStore.shared

    func handle(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        case "menu.snapshot": return snapshot()
        case "menu.toggleListening": app.toggleListening(); return .object([:])
        case "menu.openEventNotes": return try openEventNotes(params)
        case "menu.prepareSuggestion": return try prepareSuggestion(params)
        case "menu.dismissSuggestion": return try dismissSuggestion(params)
        case "menu.prepareDecision": return try prepareDecision(params)
        case "menu.markDone": return try markDone(params)
        case "menu.dismissDecision": return try dismissDecision(params)
        case "menu.approve": return try approve(params)
        case "menu.updateApproval": return try updateApproval(params)
        case "menu.undo": return try undo(params)
        case "menu.clearErrors": app.clearErrors(); return .object([:])
        case "menu.quit":
#if canImport(AppKit)
            NSApp.terminate(nil)
#endif
            return .object([:])
        default: return nil
        }
    }

    // MARK: Snapshot

    private func snapshot() -> JSONValue {
        .object([
            "isListening": .bool(app.isListening),
            "systemAudioActive": .bool(app.systemAudioActive),
            "isPlanning": .bool(app.isPlanning),
            "isConsolidating": .bool(app.isConsolidating),
            "suggestedCallApp": app.suggestedCallApp.map(JSONValue.string) ?? .null,
            "lastError": app.lastError.map(JSONValue.string) ?? .null,
            "errorLogCount": .number(Double(app.errorLog.count)),
            "upcoming": .array(upcomingSoon.map(eventJSON)),
            "suggestions": .array(app.proactiveSuggestions.map(suggestionJSON)),
            "approvals": .array(app.pendingApprovals.map(approvalJSON)),
            "detected": .array(app.detectedDecisions.map(decisionJSON)),
            "executed": .array(app.executedActions.prefix(5).map(executedActionJSON))
        ])
    }

    /// Today's and tomorrow's meetings that haven't ended yet (max 4). Mirrors
    /// MenuBarView.upcomingSoon exactly, so the web popover matches the native
    /// one it replaces.
    private var upcomingSoon: [CalendarEvent] {
        let now = Date()
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))
        else { return [] }
        return Array(app.upcomingEvents
            .filter { event in
                guard let start = event.start else { return false }
                if let end = event.end, end < now { return false }
                return start < cutoff
            }
            .prefix(4))
    }

    private static let iso = ISO8601DateFormatter()

    private func eventJSON(_ event: CalendarEvent) -> JSONValue {
        .object([
            "id": .string(event.id),
            "title": .string(event.title),
            "startISO": event.start.map { .string(Self.iso.string(from: $0)) } ?? .null,
            "endISO": event.end.map { .string(Self.iso.string(from: $0)) } ?? .null,
            "conferenceService": event.conferenceService.map(JSONValue.string) ?? .null,
            "participantSummary": event.participantSummary(excludingSelfEmail: settings.calendarSelfEmail)
                .map(JSONValue.string) ?? .null
        ])
    }

    private func suggestionJSON(_ suggestion: ProactiveSuggestion) -> JSONValue {
        .object([
            "id": .string(suggestion.id.uuidString),
            "title": .string(suggestion.title),
            "rationale": .string(suggestion.rationale)
        ])
    }

    private func decisionJSON(_ decision: Decision) -> JSONValue {
        .object([
            "id": .string(decision.id.uuidString),
            "summary": .string(decision.summary),
            "quote": .string(decision.quote),
            "intent": .string(decision.intent.rawValue),
            "confidence": .number(decision.confidence)
        ])
    }

    private func stepJSON(_ step: ActionStep) -> JSONValue {
        .object([
            "id": .string(step.id.uuidString),
            "integration": .string(step.integration.rawValue),
            "tool": .string(step.tool),
            "arguments": step.arguments,
            "riskClass": .string(step.riskClass.rawValue)
        ])
    }

    private func planJSON(_ plan: ActionPlan) -> JSONValue {
        .object([
            "id": .string(plan.id.uuidString),
            "decisionID": .string(plan.decisionID.uuidString),
            "steps": .array(plan.steps.map(stepJSON)),
            "riskClass": .string(plan.riskClass.rawValue),
            "preview": .object([
                "title": .string(plan.preview.title),
                "detail": .string(plan.preview.detail)
            ])
        ])
    }

    private func approvalJSON(_ approval: PendingApproval) -> JSONValue {
        .object([
            "id": .string(approval.id.uuidString),
            "decision": decisionJSON(approval.decision),
            "plan": planJSON(approval.plan),
            "edited": .bool(approval.edited)
        ])
    }

    private func executedActionJSON(_ action: ExecutedAction) -> JSONValue {
        .object([
            "id": .string(action.id.uuidString),
            "summary": .string(action.result.summary),
            "url": action.result.url.map(JSONValue.string) ?? .null,
            "undone": .bool(action.undone),
            "canUndo": .bool(action.canUndo)
        ])
    }

    // MARK: Lookups (the popover only ever sends ids; find the real objects app-side)

    /// A decision can be awaiting review (detectedDecisions) and/or already
    /// have a plan prepared (pendingApprovals) at the same time — see
    /// AppState.prepare, which appends an approval without removing the
    /// decision from detectedDecisions.
    private func decision(id: UUID) -> Decision? {
        app.detectedDecisions.first { $0.id == id }
            ?? app.pendingApprovals.first { $0.decision.id == id }?.decision
    }

    private func uuid(_ params: JSONValue, _ key: String) throws -> UUID {
        guard let raw = params[key]?.stringValue, let id = UUID(uuidString: raw) else {
            throw AppError.parsing("\(key) must be a UUID string")
        }
        return id
    }

    // MARK: Actions

    private func openEventNotes(_ params: JSONValue) throws -> JSONValue {
        guard let eventID = params["eventID"]?.stringValue else {
            throw AppError.parsing("eventID is required")
        }
        // The event may have scrolled out of the cached upcoming list between
        // the popover rendering it and the click — nothing to open then.
        if let event = app.upcomingEvents.first(where: { $0.id == eventID }) {
            app.openEventNotes(event)
        }
        return .object([:])
    }

    private func prepareSuggestion(_ params: JSONValue) throws -> JSONValue {
        let id = try uuid(params, "id")
        if let suggestion = app.proactiveSuggestions.first(where: { $0.id == id }) {
            app.accept(suggestion)
        }
        return .object([:])
    }

    private func dismissSuggestion(_ params: JSONValue) throws -> JSONValue {
        let id = try uuid(params, "id")
        if let suggestion = app.proactiveSuggestions.first(where: { $0.id == id }) {
            app.dismissSuggestion(suggestion)
        }
        return .object([:])
    }

    private func prepareDecision(_ params: JSONValue) throws -> JSONValue {
        let id = try uuid(params, "decisionID")
        if let decision = decision(id: id) {
            app.prepare(decision)
        }
        return .object([:])
    }

    private func markDone(_ params: JSONValue) throws -> JSONValue {
        let id = try uuid(params, "decisionID")
        if let decision = decision(id: id) {
            app.markDone(decision)
        }
        return .object([:])
    }

    private func dismissDecision(_ params: JSONValue) throws -> JSONValue {
        let id = try uuid(params, "decisionID")
        guard let reason = DismissReason(rawValue: params["reason"]?.stringValue ?? "") else {
            throw AppError.parsing("dismissDecision needs a known reason")
        }
        if let decision = decision(id: id) {
            app.dismiss(decision, reason: reason)
        }
        return .object([:])
    }

    private func approve(_ params: JSONValue) throws -> JSONValue {
        let id = try uuid(params, "approvalID")
        if let approval = app.pendingApprovals.first(where: { $0.id == id }) {
            app.approve(approval)
        }
        return .object([:])
    }

    private func updateApproval(_ params: JSONValue) throws -> JSONValue {
        let approvalID = try uuid(params, "approvalID")
        let stepID = try uuid(params, "stepID")
        guard let arguments = params["editedArguments"] else {
            throw AppError.parsing("editedArguments is required")
        }
        app.updateApproval(approvalID, editedArguments: arguments, stepID: stepID)
        return .object([:])
    }

    private func undo(_ params: JSONValue) throws -> JSONValue {
        let id = try uuid(params, "actionID")
        if let action = app.executedActions.first(where: { $0.id == id }) {
            app.undo(action)
        }
        return .object([:])
    }
}
