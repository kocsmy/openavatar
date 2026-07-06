import Foundation

/// Linear GraphQL plugin (spec §4.6). Personal API key; created issues carry
/// the 🤖 title prefix (enforced here).
struct LinearIntegration: ActionIntegration {
    let id: IntegrationID = .linear
    let apiKey: String
    /// Default team key (e.g. "ENG") from Settings; the planner can override.
    let defaultTeamKey: String
    var http = HTTPClient()
    private let api = URL(string: "https://api.linear.app/graphql")!

    private var headers: [String: String] {
        ["Authorization": apiKey, "Content-Type": "application/json"]
    }

    var toolSpecs: [ToolSpec] {
        [
            ToolSpec(name: "create_issue",
                     description: "Create a Linear issue. team_key optional (defaults to the configured team).",
                     parameters: .object([
                        "type": "object",
                        "properties": .object(["title": .object(["type": "string"]),
                                               "description": .object(["type": "string"]),
                                               "team_key": .object(["type": "string"]),
                                               "assignee": .object(["type": "string",
                                                                    "description": "assignee name or email"])]),
                        "required": .array(["title"])])),
            ToolSpec(name: "update_issue",
                     description: "Update a Linear issue's title/description/state by identifier (e.g. ENG-123). state may be: backlog, todo, in_progress, done, canceled.",
                     parameters: .object([
                        "type": "object",
                        "properties": .object(["identifier": .object(["type": "string"]),
                                               "title": .object(["type": "string"]),
                                               "description": .object(["type": "string"]),
                                               "state": .object(["type": "string"])]),
                        "required": .array(["identifier"])])),
            ToolSpec(name: "comment_on_issue",
                     description: "Comment on a Linear issue by identifier (e.g. ENG-123).",
                     parameters: .object([
                        "type": "object",
                        "properties": .object(["identifier": .object(["type": "string"]),
                                               "body": .object(["type": "string"])]),
                        "required": .array(["identifier", "body"])])),
            ToolSpec(name: "assign_issue",
                     description: "Assign a Linear issue to a person by name or email.",
                     parameters: .object([
                        "type": "object",
                        "properties": .object(["identifier": .object(["type": "string"]),
                                               "assignee": .object(["type": "string"])]),
                        "required": .array(["identifier", "assignee"])]))
        ]
    }

    func riskClass(for tool: String) -> RiskClass { .write }

    // MARK: GraphQL plumbing

    private func graphQL(_ query: String, variables: JSONValue = .object([:])) async throws -> JSONValue {
        let json = try await http.postJSON(api, headers: headers,
                                           body: .object(["query": .string(query),
                                                          "variables": variables]))
        if let errors = json["errors"]?.arrayValue, !errors.isEmpty {
            let message = errors[0]["message"]?.stringValue ?? "GraphQL error"
            throw AppError.integration("Linear: \(message)")
        }
        return json["data"] ?? .object([:])
    }

    // MARK: Execution

    func execute(_ call: ToolCall) async throws -> ActionResult {
        switch call.name {
        case "create_issue":
            let title = Attribution.prefix(call.arguments["title"]?.stringValue ?? "Untitled")
            let teamKey = call.arguments["team_key"]?.stringValue ?? defaultTeamKey
            let teamID = try await teamID(key: teamKey)
            var input: [String: JSONValue] = ["title": .string(title), "teamId": .string(teamID)]
            if let description = call.arguments["description"]?.stringValue {
                input["description"] = .string(description)
            }
            if let assignee = call.arguments["assignee"]?.stringValue,
               let userID = try await userID(nameOrEmail: assignee) {
                input["assigneeId"] = .string(userID)
            }
            let data = try await graphQL("""
                mutation($input: IssueCreateInput!) {
                  issueCreate(input: $input) { success issue { id identifier url } }
                }
                """, variables: .object(["input": .object(input)]))
            let issue = data["issueCreate"]?["issue"]
            let identifier = issue?["identifier"]?.stringValue ?? "?"
            return ActionResult(integration: id, tool: call.name,
                                summary: "Created \(identifier): \(title)",
                                url: issue?["url"]?.stringValue,
                                revertHandle: .object(["issue_id": .string(issue?["id"]?.stringValue ?? ""),
                                                       "kind": "cancel_issue"]))

        case "update_issue":
            let identifier = call.arguments["identifier"]?.stringValue ?? ""
            let issue = try await findIssue(identifier: identifier)
            var input: [String: JSONValue] = [:]
            if let title = call.arguments["title"]?.stringValue { input["title"] = .string(title) }
            if let description = call.arguments["description"]?.stringValue { input["description"] = .string(description) }
            if let stateName = call.arguments["state"]?.stringValue,
               let stateID = try await stateID(teamID: issue.teamID, name: stateName) {
                input["stateId"] = .string(stateID)
            }
            _ = try await graphQL("""
                mutation($id: String!, $input: IssueUpdateInput!) {
                  issueUpdate(id: $id, input: $input) { success }
                }
                """, variables: .object(["id": .string(issue.id), "input": .object(input)]))
            return ActionResult(integration: id, tool: call.name,
                                summary: "Updated \(identifier)", url: issue.url, revertHandle: nil)

        case "comment_on_issue":
            let identifier = call.arguments["identifier"]?.stringValue ?? ""
            let body = Attribution.prefix(call.arguments["body"]?.stringValue ?? "")
            let issue = try await findIssue(identifier: identifier)
            let data = try await graphQL("""
                mutation($input: CommentCreateInput!) {
                  commentCreate(input: $input) { success comment { id } }
                }
                """, variables: .object(["input": .object(["issueId": .string(issue.id),
                                                           "body": .string(body)])]))
            let commentID = data["commentCreate"]?["comment"]?["id"]?.stringValue ?? ""
            return ActionResult(integration: id, tool: call.name,
                                summary: "Commented on \(identifier)", url: issue.url,
                                revertHandle: .object(["comment_id": .string(commentID),
                                                       "kind": "delete_comment"]))

        case "assign_issue":
            let identifier = call.arguments["identifier"]?.stringValue ?? ""
            let assignee = call.arguments["assignee"]?.stringValue ?? ""
            let issue = try await findIssue(identifier: identifier)
            guard let userID = try await userID(nameOrEmail: assignee) else {
                throw AppError.integration("Linear user '\(assignee)' not found")
            }
            _ = try await graphQL("""
                mutation($id: String!, $input: IssueUpdateInput!) {
                  issueUpdate(id: $id, input: $input) { success }
                }
                """, variables: .object(["id": .string(issue.id),
                                         "input": .object(["assigneeId": .string(userID)])]))
            return ActionResult(integration: id, tool: call.name,
                                summary: "Assigned \(identifier) to \(assignee)",
                                url: issue.url, revertHandle: nil)

        default:
            throw AppError.integration("Unknown Linear tool: \(call.name)")
        }
    }

    /// Undo: cancel a created issue / delete a comment.
    func revert(_ result: ActionResult) async throws {
        guard let kind = result.revertHandle?["kind"]?.stringValue else {
            throw AppError.integration("No undo for this Linear action")
        }
        switch kind {
        case "cancel_issue":
            guard let issueID = result.revertHandle?["issue_id"]?.stringValue else { return }
            // Move to the team's canceled state.
            let data = try await graphQL("""
                query($id: String!) { issue(id: $id) { id team { id } } }
                """, variables: .object(["id": .string(issueID)]))
            let teamID = data["issue"]?["team"]?["id"]?.stringValue ?? ""
            guard let canceledID = try await stateID(teamID: teamID, name: "canceled") else {
                throw AppError.integration("No canceled state found")
            }
            _ = try await graphQL("""
                mutation($id: String!, $input: IssueUpdateInput!) {
                  issueUpdate(id: $id, input: $input) { success }
                }
                """, variables: .object(["id": .string(issueID),
                                         "input": .object(["stateId": .string(canceledID)])]))
        case "delete_comment":
            guard let commentID = result.revertHandle?["comment_id"]?.stringValue else { return }
            _ = try await graphQL("""
                mutation($id: String!) { commentDelete(id: $id) { success } }
                """, variables: .object(["id": .string(commentID)]))
        default:
            throw AppError.integration("No undo for this Linear action")
        }
    }

    // MARK: Lookups

    private struct FoundIssue {
        let id: String
        let teamID: String
        let url: String?
    }

    private func findIssue(identifier: String) async throws -> FoundIssue {
        let data = try await graphQL("""
            query($q: String!) {
              searchIssues(term: $q, first: 5) {
                nodes { id identifier url team { id } }
              }
            }
            """, variables: .object(["q": .string(identifier)]))
        for node in data["searchIssues"]?["nodes"]?.arrayValue ?? [] {
            if node["identifier"]?.stringValue?.caseInsensitiveCompare(identifier) == .orderedSame {
                return FoundIssue(id: node["id"]?.stringValue ?? "",
                                  teamID: node["team"]?["id"]?.stringValue ?? "",
                                  url: node["url"]?.stringValue)
            }
        }
        throw AppError.integration("Linear issue \(identifier) not found")
    }

    private func teamID(key: String) async throws -> String {
        let data = try await graphQL("query { teams(first: 50) { nodes { id key name } } }")
        let nodes = data["teams"]?["nodes"]?.arrayValue ?? []
        if let match = nodes.first(where: { $0["key"]?.stringValue?.caseInsensitiveCompare(key) == .orderedSame }) {
            return match["id"]?.stringValue ?? ""
        }
        if key.isEmpty, let first = nodes.first {
            return first["id"]?.stringValue ?? ""
        }
        throw AppError.integration("Linear team '\(key)' not found")
    }

    private func userID(nameOrEmail: String) async throws -> String? {
        let data = try await graphQL("query { users(first: 100) { nodes { id name displayName email } } }")
        for node in data["users"]?["nodes"]?.arrayValue ?? [] {
            let fields = [node["name"]?.stringValue, node["displayName"]?.stringValue,
                          node["email"]?.stringValue]
            if fields.contains(where: { $0?.caseInsensitiveCompare(nameOrEmail) == .orderedSame }) {
                return node["id"]?.stringValue
            }
        }
        return nil
    }

    private func stateID(teamID: String, name: String) async throws -> String? {
        let data = try await graphQL("""
            query($teamId: ID!) {
              workflowStates(filter: { team: { id: { eq: $teamId } } }, first: 50) {
                nodes { id name type }
              }
            }
            """, variables: .object(["teamId": .string(teamID)]))
        let wanted = name.lowercased().replacingOccurrences(of: "_", with: " ")
        for node in data["workflowStates"]?["nodes"]?.arrayValue ?? [] {
            let stateName = node["name"]?.stringValue?.lowercased() ?? ""
            let stateType = node["type"]?.stringValue?.lowercased() ?? ""
            if stateName == wanted || stateType == name.lowercased() {
                return node["id"]?.stringValue
            }
        }
        return nil
    }

    func healthCheck() async -> IntegrationHealth {
        do {
            let data = try await graphQL("query { viewer { name email } }")
            let name = data["viewer"]?["name"]?.stringValue ?? "?"
            return IntegrationHealth(ok: true, message: "Authenticated as \(name)")
        } catch {
            return IntegrationHealth(ok: false, message: Redactor.redact(error.localizedDescription))
        }
    }
}
