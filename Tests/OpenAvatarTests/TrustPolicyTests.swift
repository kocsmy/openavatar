import XCTest
@testable import OpenAvatar

final class TrustPolicyTests: XCTestCase {
    private var store: ContextStore!
    private var engine: TrustPolicyEngine!

    override func setUpWithError() throws {
        store = try ContextStore(inMemory: true)
        engine = TrustPolicyEngine(store: store)
    }

    private func step(_ integration: IntegrationID, _ tool: String, risk: RiskClass) -> ActionStep {
        ActionStep(integration: integration, tool: tool, arguments: .object([:]), riskClass: risk)
    }

    func testDefaultsAreAskFirstExceptTheTwoActiveExceptions() {
        let matrix = TrustMatrix.defaults
        XCTAssertEqual(matrix.setting(for: "github.comment_on_pr", mode: .active), .autonomous)
        XCTAssertEqual(matrix.setting(for: "linear.create_issue", mode: .active), .autonomous)
        XCTAssertEqual(matrix.setting(for: "github.comment_on_pr", mode: .passive), .askFirst)
        XCTAssertEqual(matrix.setting(for: "github.merge_pr", mode: .active), .askFirst)
        XCTAssertEqual(matrix.setting(for: "slack.post_message", mode: .active), .askFirst)
    }

    func testAskFirstWhenMatrixSaysAskFirst() {
        let verdict = engine.verdict(for: step(.slack, "post_message", risk: .write),
                                     mode: .active, decisionSource: .mic,
                                     matrix: .defaults)
        XCTAssertEqual(verdict, .askFirst)
    }

    func testAutonomousWhenMatrixAllowsNonDestructive() {
        let verdict = engine.verdict(for: step(.linear, "create_issue", risk: .write),
                                     mode: .active, decisionSource: .mic,
                                     matrix: .defaults)
        XCTAssertEqual(verdict, .autonomous)
    }

    /// Spec §5.6: destructive actions triggered by a non-user speaker are
    /// ALWAYS Ask first, regardless of the matrix.
    func testDestructiveFromSystemSourceAlwaysAsksFirst() throws {
        var matrix = TrustMatrix.defaults
        matrix.set(.autonomous, for: "github.merge_pr", mode: .active)
        try recordCleanExecutions(count: 20, tool: "merge_pr")

        let verdict = engine.verdict(for: step(.github, "merge_pr", risk: .destructive),
                                     mode: .active, decisionSource: .system,
                                     matrix: matrix)
        XCTAssertEqual(verdict, .askFirst)
    }

    /// Spec §5.6: a non-destructive (`.write`) action requested by a non-user
    /// speaker must still Ask first, even when the matrix marks it autonomous —
    /// the planner promises the user that non-user requests need approval.
    func testWriteFromSystemSourceAlwaysAsksFirst() {
        // linear.create_issue is .autonomous in Active mode by default.
        let verdict = engine.verdict(for: step(.linear, "create_issue", risk: .write),
                                     mode: .active, decisionSource: .system,
                                     matrix: .defaults)
        XCTAssertEqual(verdict, .askFirst)
    }

    /// Spec §4.7: destructive autonomy requires ≥10 clean approved executions.
    func testGraduatedAutonomyForDestructiveActions() throws {
        var matrix = TrustMatrix.defaults
        matrix.set(.autonomous, for: "github.merge_pr", mode: .active)
        let mergeStep = step(.github, "merge_pr", risk: .destructive)

        // 0 executions → still ask.
        XCTAssertEqual(engine.verdict(for: mergeStep, mode: .active,
                                      decisionSource: .mic, matrix: matrix), .askFirst)

        try recordCleanExecutions(count: 9, tool: "merge_pr")
        XCTAssertEqual(engine.verdict(for: mergeStep, mode: .active,
                                      decisionSource: .mic, matrix: matrix), .askFirst)
        XCTAssertFalse(engine.canGraduate(qualifiedTool: "github.merge_pr", riskClass: .destructive))

        try recordCleanExecutions(count: 1, tool: "merge_pr")
        XCTAssertEqual(engine.verdict(for: mergeStep, mode: .active,
                                      decisionSource: .mic, matrix: matrix), .autonomous)
        XCTAssertTrue(engine.canGraduate(qualifiedTool: "github.merge_pr", riskClass: .destructive))
    }

    func testRevertedExecutionsDoNotCountTowardGraduation() throws {
        var matrix = TrustMatrix.defaults
        matrix.set(.autonomous, for: "github.merge_pr", mode: .active)
        try recordCleanExecutions(count: 10, tool: "merge_pr", revertLast: true)

        let verdict = engine.verdict(for: step(.github, "merge_pr", risk: .destructive),
                                     mode: .active, decisionSource: .mic, matrix: matrix)
        XCTAssertEqual(verdict, .askFirst)
    }

    func testPlanVerdictIsAskFirstIfAnyStepNeedsApproval() {
        let plan = ActionPlan(
            decisionID: UUID(),
            steps: [step(.linear, "create_issue", risk: .write),
                    step(.slack, "post_message", risk: .write)],
            riskClass: .write,
            preview: ActionPreview(title: "t", detail: "d"))
        let verdict = engine.verdict(for: plan, mode: .active,
                                     decisionSource: .mic, matrix: .defaults)
        XCTAssertEqual(verdict, .askFirst)
    }

    // MARK: Helpers

    private func recordCleanExecutions(count: Int, tool: String, revertLast: Bool = false) throws {
        for i in 0..<count {
            let actionID = UUID()
            let actionStep = step(.github, tool, risk: .destructive)
            let result = ActionResult(integration: .github, tool: tool,
                                      summary: "ok", url: nil, revertHandle: nil)
            try store.recordAction(id: actionID, decisionID: UUID(), step: actionStep,
                                   result: result, editedBeforeApprove: false)
            if revertLast && i == count - 1 {
                try store.markActionReverted(actionID)
            }
        }
    }
}
