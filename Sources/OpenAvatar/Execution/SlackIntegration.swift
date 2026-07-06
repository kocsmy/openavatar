import Foundation

/// Slack plugin (spec §4.6). User token (xoxp-), BYO. Every message body is
/// prefixed 🤖 — enforced here in the executor layer, non-negotiable.
struct SlackIntegration: ActionIntegration {
    let id: IntegrationID = .slack
    let token: String
    var http = HTTPClient()
    private let api = URL(string: "https://slack.com/api")!

    private var headers: [String: String] {
        ["Authorization": "Bearer \(token)",
         "Content-Type": "application/json; charset=utf-8"]
    }

    var toolSpecs: [ToolSpec] {
        [
            ToolSpec(name: "post_message",
                     description: "Post a message to a Slack channel. Channel may be a #name or ID.",
                     parameters: .object([
                        "type": "object",
                        "properties": .object(["channel": .object(["type": "string"]),
                                               "text": .object(["type": "string"])]),
                        "required": .array(["channel", "text"])])),
            ToolSpec(name: "post_thread_reply",
                     description: "Reply in a Slack thread.",
                     parameters: .object([
                        "type": "object",
                        "properties": .object(["channel": .object(["type": "string"]),
                                               "thread_ts": .object(["type": "string"]),
                                               "text": .object(["type": "string"])]),
                        "required": .array(["channel", "thread_ts", "text"])])),
            ToolSpec(name: "send_dm",
                     description: "Send a direct message to a Slack user (by @handle or user ID).",
                     parameters: .object([
                        "type": "object",
                        "properties": .object(["user": .object(["type": "string"]),
                                               "text": .object(["type": "string"])]),
                        "required": .array(["user", "text"])]))
        ]
    }

    func riskClass(for tool: String) -> RiskClass { .write }

    func execute(_ call: ToolCall) async throws -> ActionResult {
        // 🤖 enforcement (spec §5.3): applied in code, not prompts.
        let text = Attribution.prefix(call.arguments["text"]?.stringValue ?? "")
        switch call.name {
        case "post_message":
            let channel = call.arguments["channel"]?.stringValue ?? ""
            return try await postMessage(channel: channel, text: text, threadTS: nil, tool: call.name)
        case "post_thread_reply":
            let channel = call.arguments["channel"]?.stringValue ?? ""
            let threadTS = call.arguments["thread_ts"]?.stringValue
            return try await postMessage(channel: channel, text: text, threadTS: threadTS, tool: call.name)
        case "send_dm":
            let user = call.arguments["user"]?.stringValue ?? ""
            let channel = try await openDM(user: user)
            return try await postMessage(channel: channel, text: text, threadTS: nil, tool: call.name)
        default:
            throw AppError.integration("Unknown Slack tool: \(call.name)")
        }
    }

    private func postMessage(channel: String, text: String, threadTS: String?,
                             tool: String) async throws -> ActionResult {
        var body: [String: JSONValue] = ["channel": .string(channel), "text": .string(text)]
        if let threadTS { body["thread_ts"] = .string(threadTS) }
        let json = try await http.postJSON(api.appendingPathComponent("chat.postMessage"),
                                           headers: headers, body: .object(body))
        guard json["ok"]?.boolValue == true else {
            throw AppError.integration("Slack: \(json["error"]?.stringValue ?? "unknown error")")
        }
        let ts = json["ts"]?.stringValue ?? ""
        let resolvedChannel = json["channel"]?.stringValue ?? channel
        return ActionResult(integration: id, tool: tool,
                            summary: "Posted to \(channel): \(text.prefix(80))",
                            url: nil,
                            revertHandle: .object(["channel": .string(resolvedChannel),
                                                   "ts": .string(ts)]))
    }

    private func openDM(user: String) async throws -> String {
        var userID = user
        if user.hasPrefix("@") {
            userID = try await lookupUserID(handle: String(user.dropFirst()))
        }
        let json = try await http.postJSON(api.appendingPathComponent("conversations.open"),
                                           headers: headers,
                                           body: .object(["users": .string(userID)]))
        guard json["ok"]?.boolValue == true,
              let channel = json["channel"]?["id"]?.stringValue else {
            throw AppError.integration("Slack: could not open DM with \(user)")
        }
        return channel
    }

    private func lookupUserID(handle: String) async throws -> String {
        // users.list scan; fine for v1 team sizes.
        var cursor = ""
        repeat {
            var components = URLComponents(url: api.appendingPathComponent("users.list"),
                                           resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "200")]
            if !cursor.isEmpty { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
            let json = try await http.getJSON(components.url!, headers: headers)
            for member in json["members"]?.arrayValue ?? [] {
                let name = member["name"]?.stringValue ?? ""
                let display = member["profile"]?["display_name"]?.stringValue ?? ""
                if name.caseInsensitiveCompare(handle) == .orderedSame ||
                   display.caseInsensitiveCompare(handle) == .orderedSame {
                    return member["id"]?.stringValue ?? ""
                }
            }
            cursor = json["response_metadata"]?["next_cursor"]?.stringValue ?? ""
        } while !cursor.isEmpty
        throw AppError.integration("Slack user @\(handle) not found")
    }

    /// Undo = delete the message (within Slack's edit window).
    func revert(_ result: ActionResult) async throws {
        guard let channel = result.revertHandle?["channel"]?.stringValue,
              let ts = result.revertHandle?["ts"]?.stringValue else {
            throw AppError.integration("No undo handle for this Slack message")
        }
        let json = try await http.postJSON(api.appendingPathComponent("chat.delete"),
                                           headers: headers,
                                           body: .object(["channel": .string(channel), "ts": .string(ts)]))
        guard json["ok"]?.boolValue == true else {
            throw AppError.integration("Slack delete failed: \(json["error"]?.stringValue ?? "?")")
        }
    }

    func healthCheck() async -> IntegrationHealth {
        do {
            let json = try await http.postJSON(api.appendingPathComponent("auth.test"),
                                               headers: headers, body: .object([:]))
            guard json["ok"]?.boolValue == true else {
                return IntegrationHealth(ok: false, message: json["error"]?.stringValue ?? "auth failed")
            }
            return IntegrationHealth(ok: true, message: "Authenticated as \(json["user"]?.stringValue ?? "?") in \(json["team"]?.stringValue ?? "?")")
        } catch {
            return IntegrationHealth(ok: false, message: Redactor.redact(error.localizedDescription))
        }
    }
}
