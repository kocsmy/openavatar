import Foundation

// MARK: - Neutral request/response types (spec §4.3)

enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case anthropic, openai, gemini, ollama, custom
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI (or compatible)"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (local)"
        case .custom: return "Custom"
        }
    }
}

enum ChatRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

struct ChatMessage: Codable, Sendable {
    var role: ChatRole
    var content: String
    var toolCalls: [ToolCall] = []
    /// For role == .tool: which call this message answers.
    var toolCallID: String?
    var toolName: String?

    init(role: ChatRole, content: String, toolCalls: [ToolCall] = [],
         toolCallID: String? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
    }
}

enum ToolChoice: Sendable {
    case auto
    case none
    case required
    case tool(String)
}

struct LLMRequest: Sendable {
    var model: String
    var system: String = ""
    var messages: [ChatMessage]
    var tools: [ToolSpec] = []
    var toolChoice: ToolChoice = .auto
    var maxTokens: Int = 2048
    var temperature: Double = 0.0
}

struct Usage: Codable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
}

struct LLMResponse: Sendable {
    var text: String
    var toolCalls: [ToolCall]
    var usage: Usage
    var model: String
}

enum LLMEvent: Sendable {
    case textDelta(String)
    case toolCall(ToolCall)
    case done(Usage)
}

struct ModelInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
}

// MARK: - Provider protocol

protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    func complete(_ req: LLMRequest) async throws -> LLMResponse
    func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
    /// Dynamic model listing — model names are never hard-coded in the UI.
    func listModels() async throws -> [ModelInfo]
}

/// Default streaming implementation: complete, then emit. Providers can
/// override with true SSE streaming later without changing callers.
extension LLMProvider {
    func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let resp = try await complete(req)
                    if !resp.text.isEmpty { continuation.yield(.textDelta(resp.text)) }
                    for call in resp.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.done(resp.usage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Shared HTTP helper

struct HTTPClient: Sendable {
    var timeout: TimeInterval = 120

    func send(_ method: String, _ url: URL, headers: [String: String] = [:],
              body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if body != nil, request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.http(status: -1, body: "no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = Redactor.redact(String(data: data, encoding: .utf8) ?? "")
            throw AppError.http(status: http.statusCode, body: bodyText)
        }
        return data
    }

    func postJSON(_ url: URL, headers: [String: String] = [:], body: JSONValue) async throws -> JSONValue {
        let data = try await send("POST", url, headers: headers, body: body.encodedData())
        return try JSONValue.parse(data)
    }

    func getJSON(_ url: URL, headers: [String: String] = [:]) async throws -> JSONValue {
        let data = try await send("GET", url, headers: headers)
        return try JSONValue.parse(data)
    }
}
