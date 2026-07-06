import Foundation

/// GitHub REST v3 plugin (spec §4.6). BYO fine-grained PAT.
/// merge_pr is always destructive; PRs opened by the app carry the 🤖 prefix.
struct GitHubIntegration: ActionIntegration {
    let id: IntegrationID = .github
    let token: String
    var http = HTTPClient()
    private let api = URL(string: "https://api.github.com")!

    private var headers: [String: String] {
        ["Authorization": "Bearer \(token)",
         "Accept": "application/vnd.github+json",
         "X-GitHub-Api-Version": "2022-11-28"]
    }

    // MARK: Tool specs

    private static let repoProperty: JSONValue = .object([
        "type": "string", "description": "Repository as owner/name"])

    var toolSpecs: [ToolSpec] {
        [
            ToolSpec(name: "create_branch",
                     description: "Create a new branch from the repository's default branch.",
                     parameters: .object([
                        "type": "object",
                        "properties": .object(["repo": Self.repoProperty,
                                               "branch": .object(["type": "string"])]),
                        "required": .array(["repo", "branch"])])),
            ToolSpec(name: "commit_changes",
                     description: "Commit file contents to a branch (create or update files).",
                     parameters: .object([
                        "type": "object",
                        "properties": .object([
                            "repo": Self.repoProperty,
                            "branch": .object(["type": "string"]),
                            "message": .object(["type": "string"]),
                            "files": .object(["type": "array", "items": .object([
                                "type": "object",
                                "properties": .object(["path": .object(["type": "string"]),
                                                       "content": .object(["type": "string"])]),
                                "required": .array(["path", "content"])])])
                        ]),
                        "required": .array(["repo", "branch", "message", "files"])])),
            ToolSpec(name: "open_pr",
                     description: "Open a pull request from a branch to the default branch.",
                     parameters: .object([
                        "type": "object",
                        "properties": .object(["repo": Self.repoProperty,
                                               "branch": .object(["type": "string"]),
                                               "title": .object(["type": "string"]),
                                               "body": .object(["type": "string"])]),
                        "required": .array(["repo", "branch", "title"])])),
            ToolSpec(name: "comment_on_pr",
                     description: "Post a comment on a pull request or issue.",
                     parameters: .object([
                        "type": "object",
                        "properties": .object(["repo": Self.repoProperty,
                                               "number": .object(["type": "integer"]),
                                               "body": .object(["type": "string"])]),
                        "required": .array(["repo", "number", "body"])])),
            ToolSpec(name: "merge_pr",
                     description: "Merge a pull request. Destructive — requires trust approval.",
                     parameters: .object([
                        "type": "object",
                        "properties": .object(["repo": Self.repoProperty,
                                               "number": .object(["type": "integer"])]),
                        "required": .array(["repo", "number"])])),
            ToolSpec(name: "revert_pr",
                     description: "Open a revert PR for a previously merged pull request.",
                     parameters: .object([
                        "type": "object",
                        "properties": .object(["repo": Self.repoProperty,
                                               "number": .object(["type": "integer"])]),
                        "required": .array(["repo", "number"])]))
        ]
    }

    func riskClass(for tool: String) -> RiskClass {
        switch tool {
        case "merge_pr": return .destructive          // always (spec §4.6)
        case "comment_on_pr": return .write
        case "create_branch", "commit_changes", "open_pr", "revert_pr", "push_prepared_branch": return .write
        default: return .write
        }
    }

    // MARK: Execution

    func execute(_ call: ToolCall) async throws -> ActionResult {
        let args = call.arguments
        let repo = args["repo"]?.stringValue ?? ""
        switch call.name {
        case "create_branch":
            let branch = args["branch"]?.stringValue ?? "openavatar/\(UUID().uuidString.prefix(8))"
            let defaultBranch = try await defaultBranch(repo: repo)
            let sha = try await headSHA(repo: repo, branch: defaultBranch)
            _ = try await http.postJSON(api.appendingPathComponent("repos/\(repo)/git/refs"),
                                        headers: headers,
                                        body: .object(["ref": .string("refs/heads/\(branch)"),
                                                       "sha": .string(sha)]))
            return ActionResult(integration: id, tool: call.name,
                                summary: "Created branch \(branch) in \(repo)",
                                url: "https://github.com/\(repo)/tree/\(branch)",
                                revertHandle: nil)

        case "commit_changes":
            let branch = args["branch"]?.stringValue ?? ""
            let message = Attribution.prefix(args["message"]?.stringValue ?? "Update")
            var lastSHA = ""
            for file in args["files"]?.arrayValue ?? [] {
                guard let path = file["path"]?.stringValue,
                      let content = file["content"]?.stringValue else { continue }
                lastSHA = try await putFile(repo: repo, branch: branch, path: path,
                                            content: content, message: message)
            }
            return ActionResult(integration: id, tool: call.name,
                                summary: "Committed to \(repo)@\(branch) (\(message))",
                                url: "https://github.com/\(repo)/commits/\(branch)",
                                revertHandle: lastSHA.isEmpty ? nil : .object(["sha": .string(lastSHA)]))

        case "open_pr":
            let branch = args["branch"]?.stringValue ?? ""
            let title = Attribution.prefix(args["title"]?.stringValue ?? "Change")
            let body = args["body"]?.stringValue ?? ""
            let base = try await defaultBranch(repo: repo)
            let json = try await http.postJSON(api.appendingPathComponent("repos/\(repo)/pulls"),
                                               headers: headers,
                                               body: .object(["title": .string(title),
                                                              "head": .string(branch),
                                                              "base": .string(base),
                                                              "body": .string(body)]))
            let number = json["number"]?.intValue ?? 0
            return ActionResult(integration: id, tool: call.name,
                                summary: "Opened PR #\(number): \(title)",
                                url: json["html_url"]?.stringValue,
                                revertHandle: .object(["number": .number(Double(number)),
                                                       "repo": .string(repo), "kind": "close_pr"]))

        case "comment_on_pr":
            let number = args["number"]?.intValue ?? 0
            let body = Attribution.prefix(args["body"]?.stringValue ?? "")
            let json = try await http.postJSON(api.appendingPathComponent("repos/\(repo)/issues/\(number)/comments"),
                                               headers: headers,
                                               body: .object(["body": .string(body)]))
            let commentID = json["id"]?.intValue ?? 0
            return ActionResult(integration: id, tool: call.name,
                                summary: "Commented on \(repo)#\(number)",
                                url: json["html_url"]?.stringValue,
                                revertHandle: .object(["comment_id": .number(Double(commentID)),
                                                       "repo": .string(repo), "kind": "delete_comment"]))

        case "merge_pr":
            let number = args["number"]?.intValue ?? 0
            let json = try await http.send("PUT",
                                           api.appendingPathComponent("repos/\(repo)/pulls/\(number)/merge"),
                                           headers: headers,
                                           body: try JSONValue.object([:]).encodedData())
            let parsed = try JSONValue.parse(json)
            let sha = parsed["sha"]?.stringValue ?? ""
            return ActionResult(integration: id, tool: call.name,
                                summary: "Merged PR \(repo)#\(number)",
                                url: "https://github.com/\(repo)/pull/\(number)",
                                revertHandle: .object(["sha": .string(sha),
                                                       "repo": .string(repo),
                                                       "number": .number(Double(number)),
                                                       "kind": "revert_merge"]))

        case "revert_pr":
            let number = args["number"]?.intValue ?? 0
            return try await openRevertPR(repo: repo, prNumber: number)

        case "push_prepared_branch":
            // Internal tool: the planner already prepared a local branch in the
            // app workdir (spec §4.5); push it and open the PR.
            let branch = args["branch"]?.stringValue ?? ""
            let title = Attribution.prefix(args["title"]?.stringValue ?? "Change")
            let workspace = RepoWorkspace(repo: repo, token: token)
            try workspace.push(branch: branch)
            let base = try await defaultBranch(repo: repo)
            let json = try await http.postJSON(api.appendingPathComponent("repos/\(repo)/pulls"),
                                               headers: headers,
                                               body: .object(["title": .string(title),
                                                              "head": .string(branch),
                                                              "base": .string(base),
                                                              "body": .string(args["body"]?.stringValue ?? "")]))
            let number = json["number"]?.intValue ?? 0
            return ActionResult(integration: id, tool: "open_pr",
                                summary: "Opened PR #\(number): \(title)",
                                url: json["html_url"]?.stringValue,
                                revertHandle: .object(["number": .number(Double(number)),
                                                       "repo": .string(repo), "kind": "close_pr"]))

        default:
            throw AppError.integration("Unknown GitHub tool: \(call.name)")
        }
    }

    // MARK: Revert (spec §4.8 undo)

    func revert(_ result: ActionResult) async throws {
        guard let handle = result.revertHandle, let kind = handle["kind"]?.stringValue else {
            throw AppError.integration("This GitHub action has no undo")
        }
        let repo = handle["repo"]?.stringValue ?? ""
        switch kind {
        case "close_pr":
            let number = handle["number"]?.intValue ?? 0
            _ = try await http.send("PATCH", api.appendingPathComponent("repos/\(repo)/pulls/\(number)"),
                                    headers: headers,
                                    body: try JSONValue.object(["state": "closed"]).encodedData())
        case "delete_comment":
            let commentID = handle["comment_id"]?.intValue ?? 0
            _ = try await http.send("DELETE",
                                    api.appendingPathComponent("repos/\(repo)/issues/comments/\(commentID)"),
                                    headers: headers)
        case "revert_merge":
            let number = handle["number"]?.intValue ?? 0
            _ = try await openRevertPR(repo: repo, prNumber: number)
        default:
            throw AppError.integration("This GitHub action has no undo")
        }
    }

    private func openRevertPR(repo: String, prNumber: Int) async throws -> ActionResult {
        let pr = try await http.getJSON(api.appendingPathComponent("repos/\(repo)/pulls/\(prNumber)"),
                                        headers: headers)
        guard let mergeSHA = pr["merge_commit_sha"]?.stringValue,
              pr["merged"]?.boolValue == true else {
            throw AppError.integration("PR #\(prNumber) is not merged; nothing to revert")
        }
        let base = try await defaultBranch(repo: repo)
        let branch = "openavatar/revert-pr-\(prNumber)"
        let workspace = RepoWorkspace(repo: repo, token: token)
        try workspace.revertMergeCommit(mergeSHA, defaultBranch: base, branch: branch)
        let title = Attribution.prefix("Revert PR #\(prNumber)")
        let json = try await http.postJSON(api.appendingPathComponent("repos/\(repo)/pulls"),
                                           headers: headers,
                                           body: .object(["title": .string(title),
                                                          "head": .string(branch),
                                                          "base": .string(base),
                                                          "body": .string("Reverts #\(prNumber).")]))
        return ActionResult(integration: id, tool: "revert_pr",
                            summary: "Opened revert PR for #\(prNumber)",
                            url: json["html_url"]?.stringValue,
                            revertHandle: nil)
    }

    // MARK: Helpers

    func defaultBranch(repo: String) async throws -> String {
        let json = try await http.getJSON(api.appendingPathComponent("repos/\(repo)"), headers: headers)
        return json["default_branch"]?.stringValue ?? "main"
    }

    private func headSHA(repo: String, branch: String) async throws -> String {
        let json = try await http.getJSON(api.appendingPathComponent("repos/\(repo)/git/ref/heads/\(branch)"),
                                          headers: headers)
        guard let sha = json["object"]?["sha"]?.stringValue else {
            throw AppError.parsing("No SHA for \(repo)@\(branch)")
        }
        return sha
    }

    private func putFile(repo: String, branch: String, path: String,
                         content: String, message: String) async throws -> String {
        // Fetch existing SHA if the file exists (required for updates).
        var existingSHA: String?
        var components = URLComponents(url: api.appendingPathComponent("repos/\(repo)/contents/\(path)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        if let existing = try? await http.getJSON(components.url!, headers: headers) {
            existingSHA = existing["sha"]?.stringValue
        }
        var body: [String: JSONValue] = [
            "message": .string(message),
            "content": .string(Data(content.utf8).base64EncodedString()),
            "branch": .string(branch)
        ]
        if let sha = existingSHA { body["sha"] = .string(sha) }
        let data = try await http.send("PUT", api.appendingPathComponent("repos/\(repo)/contents/\(path)"),
                                       headers: headers,
                                       body: try JSONValue.object(body).encodedData())
        let json = try JSONValue.parse(data)
        return json["commit"]?["sha"]?.stringValue ?? ""
    }

    func healthCheck() async -> IntegrationHealth {
        do {
            let json = try await http.getJSON(api.appendingPathComponent("user"), headers: headers)
            let login = json["login"]?.stringValue ?? "?"
            return IntegrationHealth(ok: true, message: "Authenticated as \(login)")
        } catch {
            return IntegrationHealth(ok: false, message: Redactor.redact(error.localizedDescription))
        }
    }
}
