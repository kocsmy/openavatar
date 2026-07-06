import Foundation

/// Single source of truth for every available integration (improvement #2):
///   1. Native Swift plugins (GitHub, Slack, Linear, Email)
///   2. Manifest-driven integrations — JSON files, no code
///   3. MCP servers — any Model Context Protocol server's tools
///
/// Built fresh on each access so Settings changes (new tokens, new manifests,
/// new servers) apply without restart, mirroring the LLM layer's behavior.
final class IntegrationRegistry: @unchecked Sendable {
    static let shared = IntegrationRegistry()

    private let keychain: KeychainStore

    init(keychain: KeychainStore = .shared) {
        self.keychain = keychain
    }

    /// User-managed manifest directory; drop a JSON file here to add an
    /// integration.
    static var manifestsDirectory: URL {
        let url = AppPaths.appSupport.appendingPathComponent("integrations", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Assembly

    /// All integrations that are configured well enough to execute.
    func active() -> [IntegrationID: any ActionIntegration] {
        var out = nativeIntegrations()
        for manifest in loadManifests() {
            let secret = keychain.secret(forIntegration: manifest.id)
            guard manifest.auth.kind == "none" || secret != nil else { continue }
            out[manifest.integrationID] = ManifestIntegration(manifest: manifest, secret: secret)
        }
        for config in MCPServerConfig.loadAll() {
            out[config.integrationID] = MCPIntegration(config: config)
        }
        return out
    }

    /// Every known integration, including ones awaiting credentials (for
    /// Settings and the trust matrix).
    struct KnownIntegration: Identifiable {
        var id: IntegrationID
        var kind: Kind
        var configured: Bool
        var authHint: String?
        enum Kind: String { case native, manifest, mcp }
    }

    func known() -> [KnownIntegration] {
        var out: [KnownIntegration] = IntegrationID.builtin.map {
            KnownIntegration(id: $0, kind: .native, configured: true, authHint: nil)
        }
        for manifest in loadManifests() {
            let configured = manifest.auth.kind == "none"
                || keychain.secret(forIntegration: manifest.id) != nil
            out.append(KnownIntegration(id: manifest.integrationID, kind: .manifest,
                                        configured: configured, authHint: manifest.auth.hint))
        }
        for config in MCPServerConfig.loadAll() {
            out.append(KnownIntegration(id: config.integrationID, kind: .mcp,
                                        configured: true, authHint: nil))
        }
        return out
    }

    /// Trust-matrix rows for non-native integrations (native rows are the
    /// curated static list). Uses cached MCP tools; manifests are sync.
    func dynamicTrustRows() -> [(qualified: String, risk: RiskClass)] {
        var rows: [(String, RiskClass)] = []
        for manifest in loadManifests() {
            for tool in manifest.tools {
                rows.append(("\(manifest.id).\(tool.name)", tool.risk))
            }
        }
        for config in MCPServerConfig.loadAll() {
            let integration = MCPIntegration(config: config)
            for spec in MCPToolCache.shared.specs(for: config.id) {
                rows.append(("\(config.integrationID.rawValue).\(spec.name)",
                             integration.riskClass(for: spec.name)))
            }
        }
        return rows
    }

    // MARK: Manifest loading

    func loadManifests() -> [IntegrationManifest] {
        var manifests: [IntegrationManifest] = []
        var seen = Set<String>()

        // Built-in starter manifests (embedded; users can override by id).
        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: Self.manifestsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in fileURLs where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? IntegrationManifest.load(from: data) else {
                NSLog("Skipping invalid integration manifest: %@", url.lastPathComponent)
                continue
            }
            guard seen.insert(manifest.id).inserted else { continue }
            manifests.append(manifest)
        }
        for json in BuiltinManifests.all {
            guard let manifest = try? IntegrationManifest.load(from: Data(json.utf8)),
                  seen.insert(manifest.id).inserted else { continue }
            manifests.append(manifest)
        }
        return manifests
    }

    // MARK: Native plugins (moved from ActionExecutor)

    private func nativeIntegrations() -> [IntegrationID: any ActionIntegration] {
        var result: [IntegrationID: any ActionIntegration] = [:]
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
}

/// Starter manifests proving the declarative pattern. Users add more as JSON
/// files in Application Support/OpenAvatar/integrations/.
enum BuiltinManifests {
    static let all = [todoist, notion]

    static let todoist = """
    {
      "id": "todoist",
      "name": "Todoist",
      "baseURL": "https://api.todoist.com/rest/v2",
      "auth": { "kind": "bearer", "hint": "Todoist API token (Settings → Integrations in Todoist)" },
      "healthCheck": { "method": "GET", "path": "/projects" },
      "tools": [
        {
          "name": "create_task",
          "description": "Create a Todoist task. due_string accepts natural language like 'tomorrow 9am'.",
          "riskClass": "write",
          "parameters": {
            "type": "object",
            "properties": {
              "content": { "type": "string", "description": "task title" },
              "description": { "type": "string" },
              "due_string": { "type": "string" }
            },
            "required": ["content"]
          },
          "attributedParams": ["content"],
          "request": {
            "method": "POST",
            "path": "/tasks",
            "body": { "content": "{{content}}", "description": "{{description}}", "due_string": "{{due_string}}" }
          },
          "response": {
            "summaryTemplate": "Created Todoist task: {{content}}",
            "urlPath": "/url",
            "revertHandle": { "task_id": "/id" }
          },
          "revert": { "method": "DELETE", "path": "/tasks/{{revert.task_id}}" }
        },
        {
          "name": "close_task",
          "description": "Complete a Todoist task by id.",
          "riskClass": "write",
          "parameters": {
            "type": "object",
            "properties": { "task_id": { "type": "string" } },
            "required": ["task_id"]
          },
          "request": { "method": "POST", "path": "/tasks/{{task_id}}/close" },
          "response": { "summaryTemplate": "Completed Todoist task {{task_id}}" }
        }
      ]
    }
    """

    static let notion = """
    {
      "id": "notion",
      "name": "Notion",
      "baseURL": "https://api.notion.com/v1",
      "auth": { "kind": "bearer", "hint": "Notion internal integration secret (notion.so/my-integrations)" },
      "healthCheck": { "method": "GET", "path": "/users/me" },
      "tools": [
        {
          "name": "create_page",
          "description": "Create a Notion page in a database. database_id required; title becomes the page title.",
          "riskClass": "write",
          "parameters": {
            "type": "object",
            "properties": {
              "database_id": { "type": "string" },
              "title": { "type": "string" }
            },
            "required": ["database_id", "title"]
          },
          "attributedParams": ["title"],
          "request": {
            "method": "POST",
            "path": "/pages",
            "body": {
              "parent": { "database_id": "{{database_id}}" },
              "properties": {
                "title": { "title": [ { "text": { "content": "{{title}}" } } ] }
              }
            }
          },
          "response": {
            "summaryTemplate": "Created Notion page: {{title}}",
            "urlPath": "/url",
            "revertHandle": { "page_id": "/id" }
          },
          "revert": {
            "method": "PATCH",
            "path": "/pages/{{revert.page_id}}",
            "body": { "archived": true }
          }
        }
      ]
    }
    """
}
