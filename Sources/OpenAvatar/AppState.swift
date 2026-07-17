import Foundation
import SwiftUI
import Combine

/// A plan waiting for the user's Approve / Edit / Dismiss (spec §4.8).
struct PendingApproval: Identifiable {
    let id = UUID()
    var decision: Decision
    var plan: ActionPlan
    var edited = false
}

/// An executed action shown in the popover with one-click Undo.
struct ExecutedAction: Identifiable {
    let id: UUID          // actionID for undo
    let result: ActionResult
    var undone = false
    var canUndo: Bool { result.revertHandle != nil && !undone }
}

struct ErrorEntry: Identifiable {
    let id = UUID()
    let at = Date()
    let message: String    // full, untruncated (secrets already redacted)
}

/// Main-actor coordinator wiring the whole pipeline:
/// capture → transcription → detection → planning → trust → execution.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Published state (menu bar + popover read these)

    @Published private(set) var isListening = false
    @Published private(set) var systemAudioActive = false
    @Published var liveSegments: [TranscriptSegment] = []
    @Published var detectedDecisions: [Decision] = []       // this call, passive accumulation
    @Published var pendingApprovals: [PendingApproval] = []
    @Published var executedActions: [ExecutedAction] = []
    @Published var lastError: String?
    @Published var errorLog: [ErrorEntry] = []
    @Published var showPostCallReview = false
    @Published var isPlanning = false
    @Published var suggestedCallApp: String?
    @Published var proactiveSuggestions: [ProactiveSuggestion] = []
    @Published var isConsolidating = false

    // Calendar context for the current call (who you're talking to).
    @Published var currentEvent: CalendarEvent?
    @Published var callAttendees: [CalendarAttendee] = []

    /// Follow-ups detected on this call, awaiting confirmation in the review.
    @Published var pendingFollowUps: [FollowUp] = []
    /// Emails already auto-assigned to a voice this call (prevents re-prefill).
    private var assignedAttendeeEmails: Set<String> = []

    let settings = SettingsStore.shared
    let store = ContextStore.shared

    // MARK: Pipeline services

    private(set) lazy var router = LLMRouter(store: store)
    private(set) lazy var executor = ActionExecutor(store: store)
    private(set) lazy var planner = ActionPlanner(router: router, store: store, executor: executor)
    private(set) lazy var detector = DecisionDetector(router: router, store: store,
                                                      wakePhrase: settings.assistantName)
    private(set) lazy var trust = TrustPolicyEngine(store: store)
    private(set) lazy var consolidator = MemoryConsolidator(router: router, store: store)
    private(set) lazy var proactive = ProactiveEngine(router: router, store: store)
    private(set) lazy var followUpExtractor = FollowUpExtractor(router: router, store: store)
    private(set) lazy var nameGuesser = SpeakerNameGuesser(router: router, store: store)
    private(set) lazy var sanitizer = ReviewSanitizer(router: router)

    private(set) lazy var diarizer = SpeakerDiarizer()
    private lazy var calendar = GoogleCalendarClient(
        tokenProvider: { try await GoogleOAuth.shared.accessToken() })
    private var capture: AudioCaptureService?
    private var currentCallID: UUID?
    private var currentCallStartedAt: Date?
    private var callDetectorTimer: Timer?
    private let callDetector = CallDetector()

    private init() {
        // Suggest (never auto-start) capture when a known call app is running.
        callDetectorTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isListening else { return }
                self.suggestedCallApp = self.callDetector.detectRunningCallApp()?.appName
            }
        }
    }

    // MARK: - Listening lifecycle (spec §4.1: icon always reflects state)

    func startListening() {
        guard !isListening else { return }
        lastError = nil
        liveSegments = []
        detectedDecisions = []
        pendingFollowUps = []
        assignedAttendeeEmails = []
        do {
            let callID = try store.startCall(app: suggestedCallApp)
            currentCallID = callID
            currentCallStartedAt = Date()
            let service = AudioCaptureService { [weak self] chunk in
                Task { @MainActor in
                    self?.handle(chunk: chunk)
                }
            }
            try service.start()
            capture = service
            isListening = true
            Task {
                await detector.updateWakePhrase(settings.assistantName)
                await diarizer.beginCall()   // reload fingerprints, fresh call state
            }
            refreshCalendar()            // identify who's on the call
        } catch {
            reportError(error)
        }
    }

    // MARK: - Calendar (who am I talking to)

    /// Look up the calendar event around now and surface its attendees so their
    /// names can pre-fill / be assigned to voices. Best-effort; never blocks.
    func refreshCalendar() {
        guard settings.calendarEnabled, GoogleOAuth.shared.isConnected else {
            currentEvent = nil
            callAttendees = []
            return
        }
        Task {
            do {
                let event = try await calendar.currentEvent()
                currentEvent = event
                callAttendees = event?.others(excludingSelfEmail: settings.calendarSelfEmail) ?? []
            } catch {
                // Calendar is a convenience; surface but never disrupt the call.
                reportError(error)
            }
        }
    }

    func stopListening() {
        guard isListening else { return }
        capture?.stop()
        capture = nil
        isListening = false

        let callID = currentCallID
        let callStart = currentCallStartedAt
        Task {
            if let callID {
                // Final detection pass, then open the post-call review sheet.
                if let fresh = try? await detector.flush(callID: callID) {
                    detectedDecisions.append(contentsOf: fresh)
                }

                // Sanity pass before the user sees anything: collapse items
                // that describe the same task worded differently. Dropped ones
                // are recorded as dismissed-duplicate, not deleted, so they
                // stay visible under "Show handled".
                if detectedDecisions.count >= 2 {
                    let (kept, droppedIDs) = await sanitizer.dedupe(detectedDecisions)
                    for id in droppedIDs {
                        try? store.updateDecisionStatus(id, status: .dismissed,
                                                        dismissReason: .duplicate)
                    }
                    detectedDecisions = kept
                }
                let summary = detectedDecisions.map(\.summary).joined(separator: "; ")
                try? store.endCall(callID, summary: summary.isEmpty ? nil : summary)

                // Capture time-referenced follow-ups to confirm in the review.
                if settings.followUpsEnabled {
                    if let found = try? await followUpExtractor.extract(
                        callID: callID, callStart: callStart ?? Date()) {
                        for f in found { try? store.insertFollowUp(f) }
                        pendingFollowUps = found
                    }
                }

                // Fold over-split voices back together before guessing names:
                // stray low-evidence "Speaker N"s merge into the call's
                // dominant voice, and a call-minted dominant voice adopts a
                // matching stored name. The store relabels saved segments;
                // mirror it into the live transcript here.
                if settings.diarizationEnabled {
                    let merges = await diarizer.consolidateCall()
                    if !merges.isEmpty {
                        var target: [String: String] = [:]
                        for (s, t) in merges { target[s.uuidString] = t.uuidString }
                        let labels = Dictionary(uniqueKeysWithValues:
                            ((try? store.allSpeakerProfiles()) ?? [])
                                .map { ($0.id.uuidString, $0.displayLabel) })
                        for i in liveSegments.indices {
                            guard var sid = liveSegments[i].speakerID else { continue }
                            // Merges can chain (stray → dominant → named person).
                            var hops = 0
                            while let next = target[sid], hops < merges.count { sid = next; hops += 1 }
                            if sid != liveSegments[i].speakerID {
                                liveSegments[i].speakerID = sid
                                liveSegments[i].speaker = labels[sid] ?? liveSegments[i].speaker
                            }
                        }
                    }
                }

                // Auto-name still-unnamed voices from transcript evidence
                // ("this is Alexa", "thanks, Vasilis"). Manual names always win;
                // best-effort and fully editable afterwards.
                if settings.diarizationEnabled {
                    if let applied = try? await nameGuesser.guessAndApply(callID: callID),
                       !applied.isEmpty {
                        for guess in applied {
                            let sid = guess.profileID.uuidString
                            for i in liveSegments.indices where liveSegments[i].speakerID == sid {
                                liveSegments[i].speaker = guess.name
                            }
                        }
                        await diarizer.reset()
                    }
                }
            }
            if !detectedDecisions.isEmpty || !pendingFollowUps.isEmpty {
                showPostCallReview = true
#if canImport(AppKit)
                WindowManager.shared.showPostCallReview()
#endif
            }
            // Compounding memory: digest the call, update facts, then see if
            // anything warrants a proactive nudge.
            if let callID {
                isConsolidating = true
                defer { isConsolidating = false }
                do {
                    try await consolidator.consolidate(callID: callID)
                    proactiveSuggestions = (try? await proactive.suggestions()) ?? proactiveSuggestions
                } catch {
                    // Memory is best-effort; never block the review flow on it.
                    NSLog("Memory consolidation failed: %@", Redactor.redact(error.localizedDescription))
                }
            }
        }
    }

    /// Re-open the post-call review for a call from history. Loads ONLY the
    /// items still awaiting a decision — anything already approved, dismissed,
    /// or executed in an earlier review stays handled and does not resurrect.
    /// Disabled while a live call is being recorded so it can't clobber the
    /// in-progress session.
    func reviewPastCall(_ callID: UUID) {
        guard !isListening else { return }
        let past = (try? store.decisions(callID: callID)) ?? []
        currentCallID = callID
        pendingApprovals = []
        pendingFollowUps = []   // don't leak the last live call's follow-ups
        detectedDecisions = past.awaitingReview
        showPostCallReview = true
#if canImport(AppKit)
        WindowManager.shared.showPostCallReview()
#endif
    }

    /// Already-handled decisions of the call currently shown in the review —
    /// the audit trail behind the "Show handled" toggle.
    func handledDecisions() -> [Decision] {
        guard let callID = currentCallID else { return [] }
        return ((try? store.decisions(callID: callID)) ?? [])
            .filter { $0.status != .detected }
    }

    // MARK: - Follow-ups (confirm in review → scheduled reminder)

    /// Confirm a suggested follow-up: mark it scheduled and set a local reminder
    /// for its due time. Requests notification permission the first time.
    func confirmFollowUp(_ followUp: FollowUp) {
        try? store.updateFollowUpStatus(id: followUp.id, status: .scheduled)
        pendingFollowUps.removeAll { $0.id == followUp.id }
        Task {
            await NotificationScheduler.requestAuthorization()
            var scheduled = followUp
            scheduled.status = .scheduled
            NotificationScheduler.schedule(scheduled)
        }
    }

    func dismissFollowUp(_ followUp: FollowUp) {
        try? store.updateFollowUpStatus(id: followUp.id, status: .dismissed)
        pendingFollowUps.removeAll { $0.id == followUp.id }
        NotificationScheduler.cancel(id: followUp.id)
    }

    func markFollowUpDone(_ followUp: FollowUp) {
        try? store.updateFollowUpStatus(id: followUp.id, status: .done)
        NotificationScheduler.cancel(id: followUp.id)
    }

    /// Push a scheduled reminder out by a number of days (default 1) and reschedule.
    func snoozeFollowUp(_ followUp: FollowUp, byDays days: Int = 1) {
        let base = max(followUp.dueAt, Date())
        let newDue = Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
        try? store.updateFollowUpDue(id: followUp.id, dueAt: newDue)
        var updated = followUp
        updated.dueAt = newDue
        updated.status = .scheduled
        NotificationScheduler.schedule(updated)
    }

    func deleteFollowUp(_ followUp: FollowUp) {
        try? store.deleteFollowUp(id: followUp.id)
        NotificationScheduler.cancel(id: followUp.id)
        pendingFollowUps.removeAll { $0.id == followUp.id }
    }

    func scheduledFollowUps() -> [FollowUp] {
        (try? store.followUps(statuses: [.scheduled])) ?? []
    }

    func completedFollowUps() -> [FollowUp] {
        (try? store.followUps(statuses: [.done])) ?? []
    }

    // MARK: - Proactive suggestions (always Ask-first)

    func accept(_ suggestion: ProactiveSuggestion) {
        proactiveSuggestions.removeAll { $0.id == suggestion.id }
        let decision = suggestion.asDecision()
        try? store.insert(decision)
        detectedDecisions.append(decision)
        prepare(decision)
    }

    func dismissSuggestion(_ suggestion: ProactiveSuggestion) {
        proactiveSuggestions.removeAll { $0.id == suggestion.id }
    }

    /// Global hotkey / menu-bar action (spec §5.1).
    func toggleListening() {
        isListening ? stopListening() : startListening()
    }

    // MARK: - Error reporting (full text kept for diagnosis, spec §4.3)

    func reportError(_ error: Error) {
        let full = Redactor.redact(error.localizedDescription)
        lastError = full
        errorLog.insert(ErrorEntry(message: full), at: 0)
        if errorLog.count > 20 { errorLog.removeLast(errorLog.count - 20) }
    }

    func clearErrors() {
        lastError = nil
        errorLog.removeAll()
    }

    // MARK: - Pipeline

    private func handle(chunk: AudioChunk) {
        guard let callID = currentCallID else { return }
        if chunk.source == .system { systemAudioActive = true }
        Task {
            do {
                let transcriber = makeTranscriber()
                var segments = try await transcriber.transcribe(chunk)
                guard !segments.isEmpty else { return }

                // Per-voice diarization on the "Others" (system) channel. Each
                // utterance is matched to a persistent voice fingerprint so a
                // named speaker keeps their name across calls.
                if settings.diarizationEnabled, chunk.source == .system {
                    for i in segments.indices {
                        if let hit = await diarizer.label(for: segments[i], in: chunk) {
                            var label = hit.label
                            // 1:1 calls: pre-fill the single other attendee's name
                            // onto the first unnamed voice we hear.
                            if let prefill = await prefillName(for: hit) { label = prefill }
                            segments[i].speaker = label
                            segments[i].speakerID = hit.id.uuidString
                        }
                    }
                }

                // Clean streaming artifacts: chunk-overlap duplicates (the
                // capture overlaps chunks by ~2s) and whisper's silence
                // hallucinations. A fuller re-decode replaces its partial.
                let (kept, deletePrevious) = TranscriptSanitizer.reconcile(
                    incoming: segments, previous: Array(liveSegments.suffix(12)))
                if !deletePrevious.isEmpty {
                    try? store.deleteSegments(Array(deletePrevious))
                    liveSegments.removeAll { deletePrevious.contains($0.id) }
                }
                guard !kept.isEmpty else { return }

                try store.insert(kept, callID: callID)
                liveSegments.append(contentsOf: kept)
                if liveSegments.count > 200 { liveSegments.removeFirst(liveSegments.count - 200) }

                let fresh = try await detector.ingest(segments: kept, callID: callID)
                for decision in fresh {
                    route(decision)
                }
            } catch {
                // Graceful degradation (spec §4.3): surface, never silently drop.
                reportError(error)
            }
        }
    }

    /// If exactly one other attendee is known and this is a still-unnamed voice,
    /// assign that attendee's name to the fingerprint (carries forward). Returns
    /// the name applied, or nil to leave the "Speaker N" label as-is.
    private func prefillName(for hit: DiarizedSpeaker) async -> String? {
        guard settings.calendarEnabled,
              hit.label.hasPrefix("Speaker "),
              callAttendees.count == 1,
              let attendee = callAttendees.first,
              !assignedAttendeeEmails.contains(attendee.id) else { return nil }
        assignedAttendeeEmails.insert(attendee.id)
        do {
            try store.renameSpeaker(id: hit.id, to: attendee.name)
            await diarizer.reset()   // so subsequent utterances use the new name
            return attendee.name
        } catch {
            reportError(error)
            return nil
        }
    }

    // MARK: - Speakers in the current call (for the editable roster UI)

    struct CallSpeaker: Identifiable, Equatable {
        let id: String          // speaker fingerprint id (UUID string)
        var label: String
        var segmentCount: Int
    }

    /// Distinct system-channel voices heard so far this call, in first-heard order.
    var callSpeakers: [CallSpeaker] {
        var order: [String] = []
        var map: [String: CallSpeaker] = [:]
        for seg in liveSegments where seg.source == .system {
            guard let sid = seg.speakerID else { continue }
            if var existing = map[sid] {
                existing.segmentCount += 1
                existing.label = seg.speaker ?? existing.label
                map[sid] = existing
            } else {
                map[sid] = CallSpeaker(id: sid, label: seg.speaker ?? "Others", segmentCount: 1)
                order.append(sid)
            }
        }
        return order.compactMap { map[$0] }
    }

    /// Rename (or clear, with nil) a voice. Persists to the fingerprint so the
    /// name applies to this call's transcript, every past call, and future calls.
    func renameSpeaker(id: String, to name: String?) {
        guard let uuid = UUID(uuidString: id) else { return }
        do {
            try store.renameSpeaker(id: uuid, to: name)
        } catch {
            reportError(error)
            return
        }
        let resolved = (try? store.allSpeakerProfiles())?.first { $0.id == uuid }?.displayLabel
        if let resolved {
            for i in liveSegments.indices where liveSegments[i].speakerID == id {
                liveSegments[i].speaker = resolved
            }
        }
        Task { await diarizer.reset() }   // reload names for ongoing diarization
    }

    /// Merge one voice into another (fixes over-splitting). Persists, updates the
    /// live transcript, and reloads the diarizer so ongoing speech follows.
    func mergeSpeaker(sourceID: String, into targetID: String) {
        guard let source = UUID(uuidString: sourceID),
              let target = UUID(uuidString: targetID), source != target else { return }
        do {
            try store.mergeSpeaker(source, into: target)
        } catch {
            reportError(error)
            return
        }
        let resolved = (try? store.allSpeakerProfiles())?.first { $0.id == target }?.displayLabel
        for i in liveSegments.indices where liveSegments[i].speakerID == sourceID {
            liveSegments[i].speakerID = targetID
        }
        if let resolved {
            for i in liveSegments.indices where liveSegments[i].speakerID == targetID {
                liveSegments[i].speaker = resolved
            }
        }
        Task { await diarizer.reset() }
    }

    /// Global cleanup of accumulated fingerprint over-splitting ("Tidy up
    /// stray voices"). Folds near-duplicate low-evidence voices into their
    /// nearest substantial match across all calls. Returns how many were folded.
    func sweepStrayVoices() -> Int {
        guard !isListening else { return 0 }
        let merged = (try? store.sweepStrayProfiles()) ?? 0
        if merged > 0 { Task { await diarizer.reset() } }
        return merged
    }

    /// Break one call's voice out of a wrongly-matched profile (the inverse of
    /// merge): that call's segments move to a fresh "Speaker N" the user can
    /// rename, while the original person keeps their name and other calls.
    /// Returns the new profile's id so the UI can focus the rename field.
    func detachSpeaker(callID: UUID, from sourceID: String) -> String? {
        guard let source = UUID(uuidString: sourceID) else { return nil }
        do {
            guard let newID = try store.detachSpeaker(callID: callID, from: source) else {
                return nil
            }
            if callID == currentCallID {
                let label = (try? store.allSpeakerProfiles())?
                    .first { $0.id == newID }?.displayLabel ?? "Others"
                for i in liveSegments.indices where liveSegments[i].speakerID == sourceID {
                    liveSegments[i].speakerID = newID.uuidString
                    liveSegments[i].speaker = label
                }
            }
            Task { await diarizer.reset() }
            return newID.uuidString
        } catch {
            reportError(error)
            return nil
        }
    }

    private func makeTranscriber() -> Transcriber {
        let prompt = transcriptionPrompt()
        switch settings.transcriptionMode {
        case .local:
            return WhisperLocalTranscriber(cliPath: settings.whisperCLIPath,
                                           modelPath: settings.whisperModelPath,
                                           language: settings.transcriptionLanguage,
                                           prompt: prompt)
        case .cloud:
            let key = KeychainStore.shared.get(.cloudSTTAPIKey) ?? ""
            return CloudTranscriber(apiKey: key,
                                    baseURL: URL(string: settings.cloudSTTBaseURL)
                                        ?? URL(string: "https://api.openai.com/v1")!,
                                    model: settings.cloudSTTModel,
                                    language: settings.transcriptionLanguage,
                                    prompt: prompt)
        }
    }

    /// Decoder-bias context for transcription: names and jargon whisper should
    /// spell correctly. Custom vocabulary from Settings, plus everything we
    /// already know about this call — named voices and calendar attendees.
    /// (This is how meeting tools get "PostHog" right where stock whisper
    /// hears "post-hog".)
    private func transcriptionPrompt() -> String {
        var terms = settings.customVocabulary
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        terms.append(settings.assistantName)
        terms += ((try? store.allSpeakerProfiles()) ?? []).compactMap(\.name)
        terms += callAttendees.map(\.name)
        var seen = Set<String>()
        let unique = terms.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard !unique.isEmpty else { return "" }
        return "Glossary: \(unique.prefix(40).joined(separator: ", "))."
    }

    /// Route a fresh decision: Active mode + directly addressed → plan now;
    /// otherwise accumulate for the post-call review (spec §4.4).
    private func route(_ decision: Decision) {
        detectedDecisions.append(decision)
        guard settings.mode == .active, decision.addressedToAssistant,
              decision.confidence >= settings.confidenceThreshold else { return }
        Task { await planAndMaybeExecute(decision) }
    }

    private func planAndMaybeExecute(_ decision: Decision) async {
        isPlanning = true
        defer { isPlanning = false }
        do {
            let plan = try await planner.plan(for: decision)
            let verdict = trust.verdict(for: plan, mode: settings.mode,
                                        decisionSource: decision.source,
                                        matrix: settings.trustMatrix)
            switch verdict {
            case .autonomous:
                try await runPlan(plan, decision: decision, edited: false)
            case .askFirst:
                pendingApprovals.append(PendingApproval(decision: decision, plan: plan))
            }
        } catch {
            reportError(error)
        }
    }

    // MARK: - Approval flow (spec §4.8)

    /// Generate the plan/preview for a passive-mode decision on demand.
    func prepare(_ decision: Decision) {
        guard !pendingApprovals.contains(where: { $0.decision.id == decision.id }) else { return }
        isPlanning = true
        Task {
            defer { isPlanning = false }
            do {
                let plan = try await planner.plan(for: decision)
                pendingApprovals.append(PendingApproval(decision: decision, plan: plan))
            } catch {
                reportError(error)
            }
        }
    }

    func approve(_ approval: PendingApproval) {
        pendingApprovals.removeAll { $0.id == approval.id }
        Task {
            do {
                try store.updateDecisionStatus(approval.decision.id,
                                               status: approval.edited ? .edited : .approved)
                try await runPlan(approval.plan, decision: approval.decision, edited: approval.edited)
            } catch {
                reportError(error)
                // Put it back so the user can retry or dismiss.
                pendingApprovals.append(approval)
            }
        }
    }

    /// Edit-before-approve is tracked — counts against auto-approve-no-edit (§6).
    func updateApproval(_ approvalID: UUID, editedArguments: JSONValue, stepID: UUID) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == approvalID }) else { return }
        var approval = pendingApprovals[index]
        if let stepIndex = approval.plan.steps.firstIndex(where: { $0.id == stepID }) {
            approval.plan.steps[stepIndex].arguments = editedArguments
            approval.edited = true
            approval.plan.preview = ActionPlanner.preview(for: approval.plan.steps,
                                                          decision: approval.decision)
            pendingApprovals[index] = approval
        }
    }

    func dismiss(_ decision: Decision, reason: DismissReason) {
        pendingApprovals.removeAll { $0.decision.id == decision.id }
        detectedDecisions.removeAll { $0.id == decision.id }
        try? store.updateDecisionStatus(decision.id, status: .dismissed, dismissReason: reason)
        try? MetricsRecorder(store: store).bump("dismissed")
    }

    private func runPlan(_ plan: ActionPlan, decision: Decision, edited: Bool) async throws {
        let steps = try await executor.execute(plan, editedBeforeApprove: edited)
        for step in steps {
            executedActions.insert(ExecutedAction(id: step.actionID, result: step.result), at: 0)
        }
        detectedDecisions.removeAll { $0.id == decision.id }
    }

    func undo(_ action: ExecutedAction) {
        Task {
            do {
                try await executor.undo(actionID: action.id)
                if let index = executedActions.firstIndex(where: { $0.id == action.id }) {
                    executedActions[index].undone = true
                }
            } catch {
                reportError(error)
            }
        }
    }
}
