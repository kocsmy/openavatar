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
    @Published var isPlanning = false
    @Published var suggestedCallApp: String?
    @Published var proactiveSuggestions: [ProactiveSuggestion] = []
    @Published var isConsolidating = false

    // Calendar context for the current call (who you're talking to).
    @Published var currentEvent: CalendarEvent?
    @Published var callAttendees: [CalendarAttendee] = []
    /// Upcoming meetings for the Home "Coming up" view.
    @Published var upcomingEvents: [CalendarEvent] = []
    /// Upcoming event whose notes the call window is showing BEFORE the call
    /// exists (Granola-style: click a meeting, pre-write your notes).
    @Published var previewEvent: CalendarEvent?

    /// Structured Markdown notes of the call currently shown in the review
    /// (arrives asynchronously from consolidation, a few seconds after the
    /// review opens).
    @Published var reviewCallNotes: String?

    /// Follow-ups detected on this call, awaiting confirmation in the review.
    @Published var pendingFollowUps: [FollowUp] = []
    /// Emails already auto-assigned to a voice this call (prevents re-prefill).
    private var assignedAttendeeEmails: Set<String> = []

    /// Parakeet (FluidAudio) model preparation, for the settings UI.
    enum ParakeetState {
        case idle, preparing, ready
        case failed(String)
    }
    @Published var parakeetState: ParakeetState = .idle

    /// Download (first time, ~600 MB) and load the Parakeet models, then make
    /// Parakeet the active engine. Safe to re-run; reflects progress in
    /// `parakeetState`.
    func prepareParakeet() {
        if case .preparing = parakeetState { return }
        parakeetState = .preparing
        Task {
            do {
                try await ParakeetTranscriber.shared.prepare()
                parakeetState = .ready
                settings.transcriptionMode = .parakeet
            } catch {
                parakeetState = .failed(Redactor.redact(error.localizedDescription))
            }
        }
    }

    /// Sync `parakeetState` with reality when the settings tab appears: models
    /// may already be loaded from an earlier call this session, or downloaded
    /// on disk from a previous run — either way the user is ready to go and
    /// must not be offered the 600 MB download again.
    func refreshParakeetState() {
        Task {
            if await ParakeetTranscriber.shared.isReady || ParakeetTranscriber.modelsOnDisk {
                parakeetState = .ready
            }
        }
    }

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
    private(set) lazy var sanitizer = ReviewSanitizer(router: router)

    private(set) lazy var diarizer = SpeakerDiarizer()
    private lazy var calendar = GoogleCalendarClient(
        tokenProvider: { try await GoogleOAuth.shared.accessToken() })
    private var capture: AudioCaptureService?
    /// The call being recorded (or, after stop, the last call) — the call
    /// window binds its notes and transcript to this.
    @Published private(set) var currentCallID: UUID?
    private var currentCallStartedAt: Date?
    private var callDetectorTimer: Timer?
    private let callDetector = CallDetector()

    private init() {
        // Every 5s, check who holds the microphone. While idle: surface the
        // suggestion banner, and (when enabled) auto-start capture on a strong
        // call signal — Granola-style, joining a Zoom call just starts the
        // notes. While listening: keep the saved call's app label honest, and
        // auto-stop auto-started sessions once the call is over.
        callDetectorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.detectorTick()
            }
        }
        // Auto-started sessions announce themselves with a notification —
        // make sure we're allowed to post it before the first call happens.
        if settings.autoStartOnCall {
            Task { await NotificationScheduler.requestAuthorization() }
        }
    }

    /// Arms/disarms automatic session start/stop; pure and unit-tested.
    private var autoPolicy = AutoSessionPolicy()
    /// Whether the current session was started by the detector. Auto-started
    /// sessions always auto-stop when their call ends; manual ones auto-stop
    /// too once a call has been observed (never for call-less dictation).
    private var sessionAutoStarted = false

    private func detectorTick() {
        let detected = callDetector.detectActiveCall(
            conferenceService: currentEvent?.conferenceService)
        if isListening {
            refreshCallAppLabel(detected: detected)
        } else {
            suggestedCallApp = detected?.appName
        }
        updateCallPrompt(detected: detected)

        // Auto-start only on a STRONG signal (a known call app, or a browser
        // during a calendar event with a meeting link) — a random app opening
        // the mic must not trigger recording.
        switch autoPolicy.tick(enabled: settings.autoStartOnCall,
                               isListening: isListening,
                               autoStarted: sessionAutoStarted,
                               callActive: detected?.strongCallSignal == true) {
        case .start:
            startListening(auto: true)
            if isListening {   // only announce if start actually succeeded
                NotificationScheduler.postNow(
                    title: "Transcribing your \(detected?.appName ?? "call")",
                    body: "A call started, so \(settings.assistantName) is taking notes. Click the menu-bar icon to stop.")
            }
        case .stop:
            stopListening(auto: true)
            NotificationScheduler.postNow(
                title: "Call ended",
                body: "Stopped transcribing — your notes and action items are ready.")
        case .none:
            break
        }
    }

    // MARK: Floating call prompt (Granola-style "Take notes?")

    /// App name shown on the floating prompt; non-nil = panel visible.
    @Published private(set) var callPromptApp: String?
    /// The user closed the prompt for the ongoing call — don't nag again
    /// until that call ends.
    private var callPromptDismissed = false

    private func updateCallPrompt(detected: CallDetector.DetectedCall?) {
        if detected == nil { callPromptDismissed = false }   // call over → fresh slate
        let show = CallPromptPolicy.shouldPrompt(
            isListening: isListening,
            callDetected: detected != nil,
            strongSignal: detected?.strongCallSignal == true,
            autoStartEnabled: settings.autoStartOnCall,
            dismissed: callPromptDismissed)
        setCallPrompt(show ? detected?.appName : nil)
    }

    private func setCallPrompt(_ appName: String?) {
        guard callPromptApp != appName else { return }
        callPromptApp = appName
#if canImport(AppKit)
        if appName != nil {
            WindowManager.shared.showCallPrompt()
        } else {
            WindowManager.shared.hideCallPrompt()
        }
#endif
    }

    /// "Take notes" on the floating prompt.
    func acceptCallPrompt() {
        setCallPrompt(nil)
        startListening()
    }

    /// ✕ on the floating prompt: silence it for the rest of this call.
    func dismissCallPrompt() {
        callPromptDismissed = true
        setCallPrompt(nil)
    }

    /// Current best label for the app hosting this call (persisted on the record).
    private var currentCallAppLabel: String?

    /// Update the call record when the detected mic owner changes — e.g. Slack
    /// was guessed at start but Zoom turns out to host the call, or the
    /// calendar event now identifies the browser call as Google Meet.
    private func refreshCallAppLabel(detected: CallDetector.DetectedCall?) {
        guard let callID = currentCallID, isListening, let detected else { return }
        guard detected.appName != currentCallAppLabel else { return }
        currentCallAppLabel = detected.appName
        try? store.updateCallApp(callID, app: detected.appName)
    }

    // MARK: - Listening lifecycle (spec §4.1: icon always reflects state)

    func startListening(auto: Bool = false) {
        guard !isListening else { return }
        lastError = nil
        liveSegments = []
        detectedDecisions = []
        pendingFollowUps = []
        assignedAttendeeEmails = []
        reviewCallNotes = nil
        previewEvent = nil   // the live call owns the notes window now
        sessionAutoStarted = auto
        autoPolicy.sessionStarted()
        setCallPrompt(nil)   // recording answers the prompt
        do {
            // Label with whoever holds the mic right now; fall back to the
            // banner's suggestion. Refined again mid-call (refreshCallAppLabel).
            let detected = callDetector.detectActiveCall(
                conferenceService: currentEvent?.conferenceService)?.appName
            currentCallAppLabel = detected ?? suggestedCallApp
            let callID = try store.startCall(app: currentCallAppLabel)
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
                await detector.beginCall()   // no rolling context from the last call
                await diarizer.beginCall()   // reload fingerprints, fresh call state
            }
            refreshCalendar()            // identify who's on the call
#if canImport(AppKit)
            // Granola-style: the call window (your notes + live transcript)
            // appears in the background without stealing focus from the call.
            WindowManager.shared.showCallWindow(focus: false)
#endif
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
                let event = try await calendar.currentEvent(calendarID: settings.calendarID)
                currentEvent = event
                callAttendees = event?.others(excludingSelfEmail: settings.calendarSelfEmail) ?? []
                if let event { adoptEventContext(event) }
            } catch {
                // Calendar is a convenience; surface but never disrupt the call.
                reportError(error)
            }
        }
    }

    /// A live call just learned which calendar event it belongs to: stamp the
    /// event's title on the record and let any notes pre-written for the event
    /// seed the call's own notes. The call window switches from event preview
    /// to the live call.
    private func adoptEventContext(_ event: CalendarEvent) {
        guard let callID = currentCallID, isListening else { return }
        try? store.updateCallTitle(callID, title: event.title)
        if let pre = try? store.eventNotes(eventID: event.id), !pre.isEmpty,
           ((try? store.callUserNotes(callID)) ?? "").isEmpty {
            try? store.updateCallUserNotes(callID, text: pre)
        }
        previewEvent = nil
    }

    /// Open the call window on an upcoming meeting so notes can be written
    /// ahead of time (they carry into the call once it starts).
    func openEventNotes(_ event: CalendarEvent) {
        previewEvent = event
#if canImport(AppKit)
        WindowManager.shared.showCallWindow()
#endif
    }

    /// Refresh the Home view's "Coming up" list. Best-effort.
    func refreshUpcomingEvents() {
        guard settings.calendarEnabled, GoogleOAuth.shared.isConnected else {
            upcomingEvents = []
            return
        }
        Task {
            if let events = try? await calendar.upcomingEvents(calendarID: settings.calendarID) {
                upcomingEvents = events
            }
        }
    }

    func stopListening(auto: Bool = false) {
        guard isListening else { return }
        capture?.stop()
        capture = nil
        isListening = false
        systemAudioActive = false
        if !auto {
            // The user hit Stop themselves. If the call is still going,
            // auto-start must not fight them by restarting seconds later —
            // and neither may the floating prompt.
            autoPolicy.userStopped(callStillActive: callDetector.detectActiveCall(
                conferenceService: currentEvent?.conferenceService)?.strongCallSignal == true)
            callPromptDismissed = true
        }
        sessionAutoStarted = false
        // Qwen's bridge holds ~4 GB; keep it warm only while it's the active
        // engine — otherwise release it now that the call is over.
        if settings.transcriptionMode != .qwen {
            Task { await Qwen3Transcriber.shared.shutdown() }
        }

        let callID = currentCallID
        let callStart = currentCallStartedAt
        // Snapshot THIS call's items now. The pipeline below is async and a
        // new session may start meanwhile (auto-start makes that likely) —
        // the shared published arrays then belong to the NEW call, so every
        // step works on the snapshot and only mirrors into the published
        // state while this call is still the current one. (Regression: two
        // back-to-back calls ended up with each other's items in their
        // digests.)
        let decisionsSnapshot = detectedDecisions
        Task {
            var callDecisions = decisionsSnapshot
            if let callID {
                // Final detection pass.
                if let fresh = try? await detector.flush(callID: callID) {
                    callDecisions.append(contentsOf: fresh)
                    if currentCallID == callID {
                        detectedDecisions.append(contentsOf: fresh)
                    }
                }

                // Sanity pass before the user sees anything: collapse items
                // that describe the same task worded differently. Dropped ones
                // are recorded as dismissed-duplicate, not deleted, so they
                // stay visible on the meeting page.
                if callDecisions.count >= 2 {
                    let (kept, droppedIDs) = await sanitizer.dedupe(callDecisions)
                    for id in droppedIDs {
                        try? store.updateDecisionStatus(id, status: .dismissed,
                                                        dismissReason: .duplicate)
                    }
                    callDecisions = kept
                    if currentCallID == callID {
                        detectedDecisions = kept
                    }
                }
                // Digest strictly from THIS call's records — never from shared
                // in-memory state that another session may own by now.
                let digestItems = ((try? store.decisions(callID: callID)) ?? [])
                    .filter { $0.status != .dismissed }
                let summary = digestItems.map(\.summary).joined(separator: "; ")
                try? store.endCall(callID, summary: summary.isEmpty ? nil : summary)

                // Persist the evolved voice centroids so the next call's
                // enrollment recognizes everyone faster. (In-call merging is
                // the backend's job now — its clustering keeps one id per
                // voice, so there are no stray speakers to fold.)
                if settings.diarizationEnabled {
                    await diarizer.endCall()
                }
            }
#if canImport(AppKit)
            // The call window flips from live notes to the finished meeting's
            // page (Actions / Summary / Transcript) — bring it forward so the
            // detected items are one glance away. No separate review window.
            WindowManager.shared.showCallWindow()
#endif
            // One post-call LLM pass does it all — digest + notes, memory
            // facts, follow-ups, and speaker names — instead of three
            // separate calls that each re-sent the same transcript.
            if let callID {
                isConsolidating = true
                defer { isConsolidating = false }
                do {
                    let outcome = try await consolidator.consolidate(
                        callID: callID, callStart: callStart ?? Date(),
                        extractFollowUps: settings.followUpsEnabled,
                        guessSpeakerNames: settings.diarizationEnabled)
                    if !outcome.notes.isEmpty, currentCallID == callID {
                        reviewCallNotes = outcome.notes
                    }
                    for f in outcome.followUps { try? store.insertFollowUp(f) }
                    if currentCallID == callID, !outcome.followUps.isEmpty {
                        pendingFollowUps = outcome.followUps
                    }
                    // Auto-detected speaker names (already persisted onto the
                    // profiles): mirror into the live transcript view only
                    // while this call still owns it.
                    if !outcome.appliedGuesses.isEmpty {
                        if currentCallID == callID {
                            for guess in outcome.appliedGuesses {
                                let sid = guess.profileID.uuidString
                                for i in liveSegments.indices where liveSegments[i].speakerID == sid {
                                    liveSegments[i].speaker = guess.name
                                }
                            }
                        }
                        await diarizer.reset()
                    }
                    proactiveSuggestions = (try? await proactive.suggestions()) ?? proactiveSuggestions
                } catch {
                    // Memory is best-effort; never block the review flow on it.
                    NSLog("Memory consolidation failed: %@", Redactor.redact(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Follow-ups (confirm on the meeting page → scheduled reminder)

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
        if chunk.source == .system, !systemAudioActive {
            systemAudioActive = true
            // Call is audibly underway — correct the label early.
            refreshCallAppLabel(detected: callDetector.detectActiveCall(
                conferenceService: currentEvent?.conferenceService))
        }
        Task {
            do {
                let transcriber = makeTranscriber()
                var segments = try await transcriber.transcribe(chunk)
                guard !segments.isEmpty else { return }

                // Per-voice diarization on the "Others" (system) channel: the
                // chunk's audio is diarized into acoustic speaker turns first,
                // then each transcript segment takes the speaker who did most
                // of the talking in its time range. Named fingerprints are
                // enrolled at call start, so names carry across calls.
                if settings.diarizationEnabled, chunk.source == .system {
                    await diarizer.ingest(chunk: chunk)
                    for i in segments.indices {
                        if let hit = await diarizer.label(for: segments[i]) {
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
        case .parakeet:
            return ParakeetTranscriber.shared   // long-lived: models load once
        case .qwen:
            return Qwen3Transcriber.shared      // long-lived: bridge stays resident
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

    /// One-click "already did it myself": the item was detected correctly but
    /// the user handled it outside the app — clear it without executing
    /// anything and without logging a misfire.
    func markDone(_ decision: Decision) {
        pendingApprovals.removeAll { $0.decision.id == decision.id }
        detectedDecisions.removeAll { $0.id == decision.id }
        try? store.updateDecisionStatus(decision.id, status: .done)
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
