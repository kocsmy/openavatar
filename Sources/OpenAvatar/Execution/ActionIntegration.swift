import Foundation

/// Spec §4.6 — each integration is a plugin. The identity model is deliberately
/// integration-local (token in, artifacts out) so a future switch to separate
/// bot identities (PRD open question R1) is a config change, not a rewrite.
protocol ActionIntegration: Sendable {
    var id: IntegrationID { get }
    /// Tools exposed to the planner LLM (sync snapshot).
    var toolSpecs: [ToolSpec] { get }
    /// Async tool discovery for integrations whose catalog lives remotely
    /// (MCP servers). Defaults to the sync snapshot.
    func loadToolSpecs() async -> [ToolSpec]
    /// Risk class per tool name (unqualified).
    func riskClass(for tool: String) -> RiskClass
    func execute(_ call: ToolCall) async throws -> ActionResult
    /// Revert where natively supported; throws otherwise.
    func revert(_ result: ActionResult) async throws
    func healthCheck() async -> IntegrationHealth
}

extension ActionIntegration {
    func loadToolSpecs() async -> [ToolSpec] { toolSpecs }

    func revert(_ result: ActionResult) async throws {
        throw AppError.integration("\(id.displayName) does not support undo for \(result.tool)")
    }
}

/// The 🤖 attribution marker (spec §5.3) — enforced in the executor layer,
/// never left to prompts.
enum Attribution {
    static let marker = "🤖"

    static func prefix(_ text: String) -> String {
        text.hasPrefix(marker) ? text : "\(marker) \(text)"
    }

    static func emailFooter(assistantName: String, userName: String) -> String {
        "\n\n—\n\(marker) Drafted and sent by \(assistantName) on behalf of \(userName)."
    }
}
