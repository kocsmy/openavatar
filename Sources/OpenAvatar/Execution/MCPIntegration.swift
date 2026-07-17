import Foundation

/// Adapts an MCP server into an ActionIntegration. Tools are namespaced under
/// the server's IntegrationID (e.g. "mcp-notion.create_page") and go through
/// the same trust matrix, approval UI, and metrics as native integrations.
struct MCPIntegration: ActionIntegration {
    let config: MCPServerConfig

    var id: IntegrationID { config.integrationID }

    /// Sync snapshot from the cache (populated by loadToolSpecs); the
    /// executor and settings prefer the async path.
    var toolSpecs: [ToolSpec] {
        MCPToolCache.shared.specs(for: config.id)
    }

    func loadToolSpecs() async -> [ToolSpec] {
        let client = await MCPConnectionPool.shared.client(for: config)
        guard let specs = try? await client.listTools() else {
            return MCPToolCache.shared.specs(for: config.id)
        }
        MCPToolCache.shared.store(specs, for: config.id)
        return specs
    }

    /// MCP servers don't declare risk; default every tool to .write so the
    /// conservative Ask-first default applies, and the user can tighten or
    /// loosen per-tool in the trust matrix. Destructive-sounding names are
    /// escalated.
    func riskClass(for tool: String) -> RiskClass {
        let destructiveMarkers = ["delete", "remove", "merge", "send", "publish",
                                  "deploy", "drop", "archive", "wipe", "revoke",
                                  "purge", "truncate", "cancel", "destroy", "reset",
                                  "close", "disable", "uninstall", "terminate", "erase"]
        if destructiveMarkers.contains(where: { tool.lowercased().contains($0) }) {
            return .destructive
        }
        return .write
    }

    /// 🤖 attribution: MCP schemas are arbitrary, so the engine prefixes the
    /// conventional text-bearing parameters (same defaults as manifests).
    func execute(_ call: ToolCall) async throws -> ActionResult {
        let arguments = ManifestIntegration.applyAttribution(
            to: call.arguments,
            params: ManifestIntegration.defaultAttributedParams)
        let client = await MCPConnectionPool.shared.client(for: config)
        let text = try await client.callTool(name: call.name, arguments: arguments)
        return ActionResult(integration: id, tool: call.name,
                            summary: String(Redactor.redact(text.isEmpty ? "\(config.name): \(call.name) succeeded" : text).prefix(300)),
                            url: nil,
                            revertHandle: nil) // MCP has no generic undo
    }

    func healthCheck() async -> IntegrationHealth {
        let client = await MCPConnectionPool.shared.client(for: config)
        do {
            let tools = try await client.listTools()
            MCPToolCache.shared.store(tools, for: config.id)
            return IntegrationHealth(ok: true, message: "\(config.name): \(tools.count) tools available")
        } catch {
            return IntegrationHealth(ok: false, message: Redactor.redact(error.localizedDescription))
        }
    }
}

/// Lock-guarded snapshot of MCP tool lists so sync UI paths (trust matrix,
/// planner catalogs built mid-call) see the last known tools without awaiting.
final class MCPToolCache: @unchecked Sendable {
    static let shared = MCPToolCache()
    private let lock = NSLock()
    private var cache: [String: [ToolSpec]] = [:]

    func specs(for serverID: String) -> [ToolSpec] {
        lock.lock(); defer { lock.unlock() }
        return cache[serverID] ?? []
    }

    func store(_ specs: [ToolSpec], for serverID: String) {
        lock.lock(); defer { lock.unlock() }
        cache[serverID] = specs
    }
}
