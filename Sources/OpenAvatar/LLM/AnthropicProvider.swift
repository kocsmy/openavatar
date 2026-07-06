import Foundation

/// Anthropic Messages API adapter. https://docs.claude.com/en/api/overview
struct AnthropicProvider: LLMProvider {
    let id: ProviderID = .anthropic
    let apiKey: String
    var baseURL = URL(string: "https://api.anthropic.com/v1")!
    var http = HTTPClient()

    private var headers: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
    }

    // MARK: Request mapping

    static func encode(_ req: LLMRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(req.model),
            "max_tokens": .number(Double(req.maxTokens)),
            "temperature": .number(req.temperature),
            "messages": .array(req.messages.compactMap(encodeMessage))
        ]
        if !req.system.isEmpty { body["system"] = .string(req.system) }
        if !req.tools.isEmpty {
            body["tools"] = .array(req.tools.map { tool in
                .object(["name": .string(tool.name),
                         "description": .string(tool.description),
                         "input_schema": tool.parameters])
            })
            switch req.toolChoice {
            case .auto: body["tool_choice"] = .object(["type": "auto"])
            case .none: break
            case .required: body["tool_choice"] = .object(["type": "any"])
            case .tool(let name): body["tool_choice"] = .object(["type": "tool", "name": .string(name)])
            }
        }
        return .object(body)
    }

    private static func encodeMessage(_ message: ChatMessage) -> JSONValue? {
        switch message.role {
        case .system:
            return nil // handled via top-level system field
        case .user:
            return .object(["role": "user", "content": .string(message.content)])
        case .assistant:
            var blocks: [JSONValue] = []
            if !message.content.isEmpty {
                blocks.append(.object(["type": "text", "text": .string(message.content)]))
            }
            for call in message.toolCalls {
                blocks.append(.object(["type": "tool_use", "id": .string(call.id),
                                       "name": .string(call.name), "input": call.arguments]))
            }
            return .object(["role": "assistant", "content": .array(blocks)])
        case .tool:
            return .object(["role": "user", "content": .array([
                .object(["type": "tool_result",
                         "tool_use_id": .string(message.toolCallID ?? ""),
                         "content": .string(message.content)])
            ])])
        }
    }

    // MARK: Response mapping

    static func decode(_ json: JSONValue) throws -> LLMResponse {
        var text = ""
        var toolCalls: [ToolCall] = []
        for block in json["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                text += block["text"]?.stringValue ?? ""
            case "tool_use":
                toolCalls.append(ToolCall(
                    id: block["id"]?.stringValue ?? UUID().uuidString,
                    name: block["name"]?.stringValue ?? "",
                    arguments: block["input"] ?? .object([:])))
            default: break
            }
        }
        let usage = Usage(
            inputTokens: json["usage"]?["input_tokens"]?.intValue ?? 0,
            outputTokens: json["usage"]?["output_tokens"]?.intValue ?? 0)
        return LLMResponse(text: text, toolCalls: toolCalls, usage: usage,
                           model: json["model"]?.stringValue ?? "")
    }

    // MARK: LLMProvider

    func complete(_ req: LLMRequest) async throws -> LLMResponse {
        let json = try await http.postJSON(baseURL.appendingPathComponent("messages"),
                                           headers: headers, body: Self.encode(req))
        return try Self.decode(json)
    }

    func listModels() async throws -> [ModelInfo] {
        let json = try await http.getJSON(baseURL.appendingPathComponent("models"), headers: headers)
        return (json["data"]?.arrayValue ?? []).compactMap { model in
            guard let id = model["id"]?.stringValue else { return nil }
            return ModelInfo(id: id, displayName: model["display_name"]?.stringValue ?? id)
        }
    }
}
