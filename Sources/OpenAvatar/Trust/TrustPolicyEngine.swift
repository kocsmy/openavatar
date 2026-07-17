import Foundation

/// Spec §4.7 — decides, per action step, whether execution needs approval.
///
/// Hard rules enforced here (not in prompts, not in UI):
/// 1. ANY step triggered by an utterance from the system stream (a non-user
///    speaker) is ALWAYS Ask first (spec §5.6). The planner prompt promises the
///    user that requests spoken by other participants "will always require the
///    user's explicit approval", so that guarantee is enforced here for every
///    risk class, not just destructive ones.
/// 2. `.destructive` steps run autonomously only after ≥10 approved executions
///    of that action type with no revert and no pre-approval edit
///    (graduated autonomy).
struct TrustPolicyEngine {
    let store: ContextStore

    static let graduationThreshold = 10

    enum Verdict: Equatable {
        case askFirst
        case autonomous
    }

    func verdict(for step: ActionStep, mode: AssistantMode,
                 decisionSource: AudioSource, matrix: TrustMatrix) -> Verdict {
        // Rule 1: any action requested by a non-user speaker → always ask.
        // A `.write` step is not "safe" just because it isn't destructive: the
        // user never spoke it, so it must not run autonomously regardless of the
        // matrix (which otherwise marks e.g. linear.create_issue autonomous in
        // Active mode).
        if decisionSource == .system {
            return .askFirst
        }

        guard matrix.setting(for: step.qualifiedTool, mode: mode) == .autonomous else {
            return .askFirst
        }

        // Rule 2: graduated autonomy for destructive actions.
        if step.riskClass == .destructive {
            let clean = (try? store.cleanApprovedExecutions(qualifiedTool: step.qualifiedTool)) ?? 0
            if clean < Self.graduationThreshold {
                return .askFirst
            }
        }
        return .autonomous
    }

    /// A whole plan is autonomous only if every step is.
    func verdict(for plan: ActionPlan, mode: AssistantMode,
                 decisionSource: AudioSource, matrix: TrustMatrix) -> Verdict {
        for step in plan.steps {
            if verdict(for: step, mode: mode, decisionSource: decisionSource, matrix: matrix) == .askFirst {
                return .askFirst
            }
        }
        return .autonomous
    }

    /// Used by the settings UI: can the user even flip this destructive tool
    /// to Autonomous yet?
    func canGraduate(qualifiedTool: String, riskClass: RiskClass) -> Bool {
        guard riskClass == .destructive else { return true }
        let clean = (try? store.cleanApprovedExecutions(qualifiedTool: qualifiedTool)) ?? 0
        return clean >= Self.graduationThreshold
    }
}
