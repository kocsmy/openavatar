import Foundation

/// Spec §4.6 orchestration — builds the plugin registry from current keys,
/// executes plans step by step, records every action + outcome, and provides
/// one-click undo where integrations support it (spec §4.8).
actor ActionExecutor {
    private let keychain: KeychainStore
    private let store: ContextStore

    /// actionID → result, for undo.
    private var executed: [UUID: ActionResult] = [:]

    init(keychain: KeychainStore = .shared, store: ContextStore) {
        self.keychain = keychain
        self.store = store
    }

    // MARK: Registry (constructed fresh so Settings changes apply immediately)

    func integrations() -> [IntegrationID: ActionIntegration] {
        var result: [IntegrationID: ActionIntegration] = [:]
        let d = UserDefaults.standard
        if let token = keychain.get(.githubToken) {
            result[.github] = GitHubIntegration(token: token)
        }
        if let token = keychain.get(.slackUserToken) {
            result[.slack] = SlackIntegration(token: token)
        }
        if let key = keychain.get(.linearAPIKey) {
            result[.linear] = LinearIntegration(apiKey: key,
                                                defaultTeamKey: d.string(forKey: "linearTeamKey") ?? "")
        }
        let emailConfig = EmailIntegration.Config(
            backend: EmailBackend(rawValue: d.string(forKey: "emailBackend") ?? "") ?? .smtp,
            smtpHost: d.string(forKey: "smtpHost") ?? "",
            smtpPort: d.object(forKey: "smtpPort") as? Int ?? 465,
            smtpUsername: d.string(forKey: "smtpUsername") ?? "",
            smtpPassword: keychain.get(.smtpPassword),
            gmailAccessToken: keychain.get(.gmailAccessToken),
            fromAddress: d.string(forKey: "emailFromAddress") ?? "",
            assistantName: d.string(forKey: "assistantName") ?? "Avatar",
            userName: d.string(forKey: "userDisplayName") ?? NSFullUserName())
        if emailConfig.backend == .gmail ? emailConfig.gmailAccessToken != nil
                                         : !emailConfig.smtpHost.isEmpty {
            result[.email] = EmailIntegration(config: emailConfig)
        }
        return result
    }

    /// Tool catalog for the planner: every configured integration's tools with
    /// qualified names and risk classes.
    struct CatalogEntry: Sendable {
        let integration: IntegrationID
        let spec: ToolSpec
        let riskClass: RiskClass
    }

    func toolCatalog() -> [CatalogEntry] {
        integrations().values.flatMap { integration in
            integration.toolSpecs.map { spec in
                CatalogEntry(integration: integration.id, spec: spec,
                             riskClass: integration.riskClass(for: spec.name))
            }
        }
    }

    func riskClass(integration integrationID: IntegrationID, tool: String) -> RiskClass {
        integrations()[integrationID]?.riskClass(for: tool) ?? .destructive
    }

    // MARK: Execution

    struct ExecutedStep: Sendable {
        let actionID: UUID
        let result: ActionResult
    }

    /// Executes a plan sequentially. Approved-but-gated plans are executed by
    /// the app — never exported as a to-do (spec §4.7). Records each action
    /// with the edited-before-approve flag for the §6 metrics.
    func execute(_ plan: ActionPlan, editedBeforeApprove: Bool) async throws -> [ExecutedStep] {
        let registry = integrations()
        var results: [ExecutedStep] = []
        for step in plan.steps {
            guard let integration = registry[step.integration] else {
                throw AppError.notConfigured("\(step.integration.displayName) is not connected")
            }
            let call = ToolCall(id: step.id.uuidString, name: step.tool, arguments: step.arguments)
            let result = try await integration.execute(call)
            let actionID = UUID()
            executed[actionID] = result
            try? store.recordAction(id: actionID, decisionID: plan.decisionID, step: step,
                                    result: result, editedBeforeApprove: editedBeforeApprove)
            results.append(ExecutedStep(actionID: actionID, result: result))
        }
        try? store.updateDecisionStatus(plan.decisionID, status: .executed)
        try? MetricsRecorder(store: store).bump("executed")
        if editedBeforeApprove {
            try? MetricsRecorder(store: store).bump("edited")
        } else {
            try? MetricsRecorder(store: store).bump("auto_approved_no_edit")
        }
        return results
    }

    /// One-click undo (spec §4.8). Feeds the revert counter-metric.
    func undo(actionID: UUID) async throws {
        guard let result = executed[actionID] else {
            throw AppError.integration("Nothing to undo for this action")
        }
        guard let integration = integrations()[result.integration] else {
            throw AppError.notConfigured("\(result.integration.displayName) is not connected")
        }
        try await integration.revert(result)
        try? store.markActionReverted(actionID)
    }

    func healthChecks() async -> [IntegrationID: IntegrationHealth] {
        var results: [IntegrationID: IntegrationHealth] = [:]
        for (id, integration) in integrations() {
            results[id] = await integration.healthCheck()
        }
        return results
    }
}
