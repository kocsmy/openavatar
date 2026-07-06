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
    @Published var showPostCallReview = false
    @Published var isPlanning = false
    @Published var suggestedCallApp: String?

    let settings = SettingsStore.shared
    let store = ContextStore.shared

    // MARK: Pipeline services

    private(set) lazy var router = LLMRouter(store: store)
    private(set) lazy var executor = ActionExecutor(store: store)
    private(set) lazy var planner = ActionPlanner(router: router, store: store, executor: executor)
    private(set) lazy var detector = DecisionDetector(router: router, store: store,
                                                      wakePhrase: settings.assistantName)
    private(set) lazy var trust = TrustPolicyEngine(store: store)

    private var capture: AudioCaptureService?
    private var currentCallID: UUID?
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
        do {
            let callID = try store.startCall(app: suggestedCallApp)
            currentCallID = callID
            let service = AudioCaptureService { [weak self] chunk in
                Task { @MainActor in
                    self?.handle(chunk: chunk)
                }
            }
            try service.start()
            capture = service
            isListening = true
            Task { await detector.updateWakePhrase(settings.assistantName) }
        } catch {
            lastError = Redactor.redact(error.localizedDescription)
        }
    }

    func stopListening() {
        guard isListening else { return }
        capture?.stop()
        capture = nil
        isListening = false

        let callID = currentCallID
        Task {
            if let callID {
                // Final detection pass, then open the post-call review sheet.
                if let fresh = try? await detector.flush(callID: callID) {
                    detectedDecisions.append(contentsOf: fresh)
                }
                let summary = detectedDecisions.map(\.summary).joined(separator: "; ")
                try? store.endCall(callID, summary: summary.isEmpty ? nil : summary)
            }
            if !detectedDecisions.isEmpty {
                showPostCallReview = true
#if canImport(AppKit)
                WindowManager.shared.showPostCallReview()
#endif
            }
        }
    }

    /// Global hotkey / menu-bar action (spec §5.1).
    func toggleListening() {
        isListening ? stopListening() : startListening()
    }

    // MARK: - Pipeline

    private func handle(chunk: AudioChunk) {
        guard let callID = currentCallID else { return }
        if chunk.source == .system { systemAudioActive = true }
        Task {
            do {
                let transcriber = makeTranscriber()
                let segments = try await transcriber.transcribe(chunk)
                guard !segments.isEmpty else { return }
                try store.insert(segments, callID: callID)
                liveSegments.append(contentsOf: segments)
                if liveSegments.count > 200 { liveSegments.removeFirst(liveSegments.count - 200) }

                let fresh = try await detector.ingest(segments: segments, callID: callID)
                for decision in fresh {
                    route(decision)
                }
            } catch {
                // Graceful degradation (spec §4.3): surface, never silently drop.
                lastError = Redactor.redact(error.localizedDescription)
            }
        }
    }

    private func makeTranscriber() -> Transcriber {
        switch settings.transcriptionMode {
        case .local:
            return WhisperLocalTranscriber(cliPath: settings.whisperCLIPath,
                                           modelPath: settings.whisperModelPath)
        case .cloud:
            let key = KeychainStore.shared.get(.cloudSTTAPIKey) ?? ""
            return CloudTranscriber(apiKey: key,
                                    baseURL: URL(string: settings.cloudSTTBaseURL)
                                        ?? URL(string: "https://api.openai.com/v1")!,
                                    model: settings.cloudSTTModel)
        }
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
            lastError = Redactor.redact(error.localizedDescription)
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
                lastError = Redactor.redact(error.localizedDescription)
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
                lastError = Redactor.redact(error.localizedDescription)
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
                lastError = Redactor.redact(error.localizedDescription)
            }
        }
    }
}
