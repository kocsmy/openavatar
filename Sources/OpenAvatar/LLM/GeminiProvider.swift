import Foundation

/// Google Gemini generateContent REST adapter. System prompt maps to
/// `systemInstruction`; tools map to `functionDeclarations` (spec §4.3).
struct GeminiProvider: LLMProvider {
    let id: ProviderID = .gemini
    let apiKey: String
    var baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    var http = HTTPClient()

    // MARK: Request mapping

    static func encode(_ req: LLMRequest) -> JSONValue {
        var contents: [JSONValue] = []
        for message in req.messages {
            switch message.role {
            case .system:
                continue // mapped to systemInstruction
            case .user:
                contents.append(.object(["role": "user",
                                         "parts": .array([.object(["text": .string(message.content)])])]))
            case .assistant:
                var parts: [JSONValue] = []
                if !message.content.isEmpty {
                    parts.append(.object(["text": .string(message.content)]))
                }
                for call in message.toolCalls {
                    parts.append(.object(["functionCall": .object([
                        "name": .string(call.name), "args": call.arguments])]))
                }
                contents.append(.object(["role": "model", "parts": .array(parts)]))
            case .tool:
                let response: JSONValue = (try? JSONValue.parse(message.content)) ?? .object(["result": .string(message.content)])
                contents.append(.object(["role": "user", "parts": .array([
                    .object(["functionResponse": .object([
                        "name": .string(message.toolName ?? ""),
                        "response": response])])])]))
            }
        }

        var generationConfig: [String: JSONValue] = [
            "maxOutputTokens": .number(Double(req.maxTokens))
        ]
        if let temperature = req.temperature {
            generationConfig["temperature"] = .number(temperature)
        }
        var body: [String: JSONValue] = [
            "contents": .array(contents),
            "generationConfig": .object(generationConfig)
        ]
        if !req.system.isEmpty {
            body["systemInstruction"] = .object(["parts": .array([.object(["text": .string(req.system)])])])
        }
        if !req.tools.isEmpty {
            body["tools"] = .array([.object(["functionDeclarations": .array(req.tools.map { tool in
                .object(["name": .string(tool.name),
                         "description": .string(tool.description),
                         "parameters": tool.parameters])
            })])])
            switch req.toolChoice {
            case .auto:
                body["toolConfig"] = .object(["functionCallingConfig": .object(["mode": "AUTO"])])
            case .none:
                body["toolConfig"] = .object(["functionCallingConfig": .object(["mode": "NONE"])])
            case .required:
                body["toolConfig"] = .object(["functionCallingConfig": .object(["mode": "ANY"])])
            case .tool(let name):
                body["toolConfig"] = .object(["functionCallingConfig": .object([
                    "mode": "ANY", "allowedFunctionNames": .array([.string(name)])])])
            }
        }
        return .object(body)
    }

    // MARK: Response mapping

    static func decode(_ json: JSONValue, model: String) throws -> LLMResponse {
        var text = ""
        var toolCalls: [ToolCall] = []
        let parts = json["candidates"]?[0]?["content"]?["parts"]?.arrayValue ?? []
        for part in parts {
            if let t = part["text"]?.stringValue { text += t }
            if let functionCall = part["functionCall"] {
                toolCalls.append(ToolCall(id: UUID().uuidString,
                                          name: functionCall["name"]?.stringValue ?? "",
                                          arguments: functionCall["args"] ?? .object([:])))
            }
        }
        let usage = Usage(inputTokens: json["usageMetadata"]?["promptTokenCount"]?.intValue ?? 0,
                          outputTokens: json["usageMetadata"]?["candidatesTokenCount"]?.intValue ?? 0)
        return LLMResponse(text: text, toolCalls: toolCalls, usage: usage, model: model)
    }

    // MARK: LLMProvider

    func complete(_ req: LLMRequest) async throws -> LLMResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("models/\(req.model):generateContent"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        let json = try await http.postJSON(components.url!, body: Self.encode(req))
        return try Self.decode(json, model: req.model)
    }

    func listModels() async throws -> [ModelInfo] {
        var components = URLComponents(url: baseURL.appendingPathComponent("models"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey),
                                 URLQueryItem(name: "pageSize", value: "100")]
        let json = try await http.getJSON(components.url!)
        return (json["models"]?.arrayValue ?? []).compactMap { model in
            guard let name = model["name"]?.stringValue else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            return ModelInfo(id: id, displayName: model["displayName"]?.stringValue ?? id)
        }
    }
}
