import Foundation

/// Local Ollama adapter (no auth). Surfaces a distinct "Ollama not running"
/// state so the UI can prompt the user (spec §4.3).
struct OllamaProvider: LLMProvider {
    let id: ProviderID = .ollama
    var baseURL = URL(string: "http://localhost:11434")!
    var http = HTTPClient()

    // MARK: Request mapping

    static func encode(_ req: LLMRequest) -> JSONValue {
        var messages: [JSONValue] = []
        if !req.system.isEmpty {
            messages.append(.object(["role": "system", "content": .string(req.system)]))
        }
        for message in req.messages {
            switch message.role {
            case .system:
                messages.append(.object(["role": "system", "content": .string(message.content)]))
            case .user:
                messages.append(.object(["role": "user", "content": .string(message.content)]))
            case .assistant:
                var obj: [String: JSONValue] = ["role": "assistant", "content": .string(message.content)]
                if !message.toolCalls.isEmpty {
                    obj["tool_calls"] = .array(message.toolCalls.map { call in
                        .object(["function": .object(["name": .string(call.name),
                                                      "arguments": call.arguments])])
                    })
                }
                messages.append(.object(obj))
            case .tool:
                messages.append(.object(["role": "tool", "content": .string(message.content)]))
            }
        }
        var options: [String: JSONValue] = [
            "num_predict": .number(Double(req.maxTokens))
        ]
        if let temperature = req.temperature {
            options["temperature"] = .number(temperature)
        }
        var body: [String: JSONValue] = [
            "model": .string(req.model),
            "messages": .array(messages),
            "stream": .bool(false),
            "options": .object(options)
        ]
        if !req.tools.isEmpty {
            body["tools"] = .array(req.tools.map { tool in
                .object(["type": "function", "function": .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.parameters])])
            })
        }
        return .object(body)
    }

    // MARK: Response mapping

    static func decode(_ json: JSONValue, model: String) throws -> LLMResponse {
        let message = json["message"]
        let text = message?["content"]?.stringValue ?? ""
        let toolCalls: [ToolCall] = (message?["tool_calls"]?.arrayValue ?? []).compactMap { call in
            guard let function = call["function"] else { return nil }
            return ToolCall(id: UUID().uuidString,
                            name: function["name"]?.stringValue ?? "",
                            arguments: function["arguments"] ?? .object([:]))
        }
        let usage = Usage(inputTokens: json["prompt_eval_count"]?.intValue ?? 0,
                          outputTokens: json["eval_count"]?.intValue ?? 0)
        return LLMResponse(text: text, toolCalls: toolCalls, usage: usage, model: model)
    }

    // MARK: LLMProvider

    func complete(_ req: LLMRequest) async throws -> LLMResponse {
        do {
            let json = try await http.postJSON(baseURL.appendingPathComponent("api/chat"),
                                               body: Self.encode(req))
            return try Self.decode(json, model: req.model)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw AppError.notConfigured("Ollama is not running at \(baseURL.absoluteString)")
        }
    }

    func listModels() async throws -> [ModelInfo] {
        do {
            let json = try await http.getJSON(baseURL.appendingPathComponent("api/tags"))
            return (json["models"]?.arrayValue ?? []).compactMap { model in
                guard let name = model["name"]?.stringValue else { return nil }
                return ModelInfo(id: name, displayName: name)
            }
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw AppError.notConfigured("Ollama is not running at \(baseURL.absoluteString)")
        }
    }
}
