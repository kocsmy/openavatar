import Foundation

/// OpenAI Chat Completions adapter. The base URL is overridable, which also
/// covers OpenAI-compatible gateways (spec §4.3).
struct OpenAIProvider: LLMProvider {
    var id: ProviderID = .openai
    let apiKey: String
    var baseURL = URL(string: "https://api.openai.com/v1")!
    var http = HTTPClient()

    private var headers: [String: String] {
        ["Authorization": "Bearer \(apiKey)"]
    }

    // MARK: Request mapping

    static func encode(_ req: LLMRequest) -> JSONValue {
        var messages: [JSONValue] = []
        if !req.system.isEmpty {
            messages.append(.object(["role": "system", "content": .string(req.system)]))
        }
        for message in req.messages {
            messages.append(encodeMessage(message))
        }
        var body: [String: JSONValue] = [
            "model": .string(req.model),
            "messages": .array(messages),
            "max_tokens": .number(Double(req.maxTokens))
        ]
        if let temperature = req.temperature {
            body["temperature"] = .number(temperature)
        }
        if !req.tools.isEmpty {
            body["tools"] = .array(req.tools.map { tool in
                .object(["type": "function", "function": .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.parameters
                ])])
            })
            switch req.toolChoice {
            case .auto: body["tool_choice"] = "auto"
            case .none: body["tool_choice"] = "none"
            case .required: body["tool_choice"] = "required"
            case .tool(let name):
                body["tool_choice"] = .object(["type": "function",
                                               "function": .object(["name": .string(name)])])
            }
        }
        return .object(body)
    }

    private static func encodeMessage(_ message: ChatMessage) -> JSONValue {
        switch message.role {
        case .system:
            return .object(["role": "system", "content": .string(message.content)])
        case .user:
            return .object(["role": "user", "content": .string(message.content)])
        case .assistant:
            var obj: [String: JSONValue] = ["role": "assistant"]
            obj["content"] = message.content.isEmpty ? .null : .string(message.content)
            if !message.toolCalls.isEmpty {
                obj["tool_calls"] = .array(message.toolCalls.map { call in
                    .object(["id": .string(call.id), "type": "function",
                             "function": .object(["name": .string(call.name),
                                                  "arguments": .string(call.arguments.encodedString())])])
                })
            }
            return .object(obj)
        case .tool:
            return .object(["role": "tool",
                            "tool_call_id": .string(message.toolCallID ?? ""),
                            "content": .string(message.content)])
        }
    }

    // MARK: Response mapping

    static func decode(_ json: JSONValue) throws -> LLMResponse {
        guard let message = json["choices"]?[0]?["message"] else {
            throw AppError.parsing("OpenAI response missing choices[0].message")
        }
        let text = message["content"]?.stringValue ?? ""
        let toolCalls: [ToolCall] = (message["tool_calls"]?.arrayValue ?? []).compactMap { call in
            guard let function = call["function"] else { return nil }
            let argsString = function["arguments"]?.stringValue ?? "{}"
            let args = (try? JSONValue.parse(argsString)) ?? .object([:])
            return ToolCall(id: call["id"]?.stringValue ?? UUID().uuidString,
                            name: function["name"]?.stringValue ?? "",
                            arguments: args)
        }
        let usage = Usage(inputTokens: json["usage"]?["prompt_tokens"]?.intValue ?? 0,
                          outputTokens: json["usage"]?["completion_tokens"]?.intValue ?? 0)
        return LLMResponse(text: text, toolCalls: toolCalls, usage: usage,
                           model: json["model"]?.stringValue ?? "")
    }

    // MARK: LLMProvider

    func complete(_ req: LLMRequest) async throws -> LLMResponse {
        let json = try await http.postJSON(baseURL.appendingPathComponent("chat/completions"),
                                           headers: headers, body: Self.encode(req))
        return try Self.decode(json)
    }

    func listModels() async throws -> [ModelInfo] {
        let json = try await http.getJSON(baseURL.appendingPathComponent("models"), headers: headers)
        return (json["data"]?.arrayValue ?? []).compactMap { model in
            guard let id = model["id"]?.stringValue else { return nil }
            return ModelInfo(id: id, displayName: id)
        }
    }
}
