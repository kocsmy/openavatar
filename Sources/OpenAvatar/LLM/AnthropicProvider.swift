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
        var messages = req.messages.compactMap(encodeMessage)
        if req.cacheConversation, !messages.isEmpty {
            // Multi-turn loops: a breakpoint on the last message caches the
            // whole conversation so far — the next iteration re-reads it at
            // ~10% instead of re-billing every prior turn at full price.
            messages[messages.count - 1] = markingLastBlockCached(messages[messages.count - 1])
        }
        var body: [String: JSONValue] = [
            "model": .string(req.model),
            "max_tokens": .number(Double(req.maxTokens)),
            "messages": .array(messages)
        ]
        // Only send temperature when explicitly requested — newer Claude
        // models return 400 if it is present at all.
        if let temperature = req.temperature {
            body["temperature"] = .number(temperature)
        }
        if !req.system.isEmpty {
            if req.cachePrefix {
                // cache_control on the last system block caches the whole
                // prefix (tools render before system), so repeated calls with
                // an identical prompt bill the prefix at ~10% after the first.
                body["system"] = .array([.object([
                    "type": "text",
                    "text": .string(req.system),
                    "cache_control": .object(["type": "ephemeral"])
                ])])
            } else {
                body["system"] = .string(req.system)
            }
        }
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

    /// cache_control lives on content BLOCKS, so a plain-string message is
    /// promoted to block form and the marker goes on the last block.
    static func markingLastBlockCached(_ message: JSONValue) -> JSONValue {
        guard var object = message.objectValue else { return message }
        let cache: JSONValue = .object(["type": "ephemeral"])
        if let text = object["content"]?.stringValue {
            object["content"] = .array([.object([
                "type": "text", "text": .string(text), "cache_control": cache
            ])])
        } else if var blocks = object["content"]?.arrayValue,
                  var lastBlock = blocks.last?.objectValue {
            lastBlock["cache_control"] = cache
            blocks[blocks.count - 1] = .object(lastBlock)
            object["content"] = .array(blocks)
        }
        return .object(object)
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
            outputTokens: json["usage"]?["output_tokens"]?.intValue ?? 0,
            cacheReadTokens: json["usage"]?["cache_read_input_tokens"]?.intValue ?? 0,
            cacheWriteTokens: json["usage"]?["cache_creation_input_tokens"]?.intValue ?? 0)
        return LLMResponse(text: text, toolCalls: toolCalls, usage: usage,
                           model: json["model"]?.stringValue ?? "")
    }

    // MARK: LLMProvider

    func complete(_ req: LLMRequest) async throws -> LLMResponse {
        let json = try await http.postJSON(baseURL.appendingPathComponent("messages"),
                                           headers: headers, body: Self.encode(req))
        return try Self.decode(json)
    }

    /// True SSE streaming, so an answer can be shown as it is written instead
    /// of arriving as a finished wall of text. Overrides the protocol's
    /// complete-then-emit default; providers without an override still work,
    /// they just deliver the whole answer in one delta.
    func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    var body = Self.encode(req).objectValue ?? [:]
                    body["stream"] = .bool(true)
                    let lines = try await http.postSSE(baseURL.appendingPathComponent("messages"),
                                                       headers: headers, body: .object(body))
                    var usage = Usage()
                    // Tool calls stream as a name up front and their arguments
                    // as JSON fragments, so they are reassembled per block.
                    var toolIDs: [Int: String] = [:]
                    var toolNames: [Int: String] = [:]
                    var toolArgs: [Int: String] = [:]

                    for try await line in lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]",
                              let json = try? JSONValue.parse(Data(payload.utf8)) else { continue }

                        switch json["type"]?.stringValue {
                        case "message_start":
                            let reported = json["message"]?["usage"]
                            usage.inputTokens = reported?["input_tokens"]?.intValue ?? 0
                            usage.cacheReadTokens = reported?["cache_read_input_tokens"]?.intValue ?? 0
                            usage.cacheWriteTokens = reported?["cache_creation_input_tokens"]?.intValue ?? 0
                        case "content_block_start":
                            if let index = json["index"]?.intValue,
                               json["content_block"]?["type"]?.stringValue == "tool_use" {
                                toolIDs[index] = json["content_block"]?["id"]?.stringValue ?? ""
                                toolNames[index] = json["content_block"]?["name"]?.stringValue ?? ""
                                toolArgs[index] = ""
                            }
                        case "content_block_delta":
                            if let text = json["delta"]?["text"]?.stringValue, !text.isEmpty {
                                continuation.yield(.textDelta(text))
                            } else if let fragment = json["delta"]?["partial_json"]?.stringValue,
                                      let index = json["index"]?.intValue {
                                toolArgs[index, default: ""] += fragment
                            }
                        case "content_block_stop":
                            if let index = json["index"]?.intValue, let name = toolNames[index] {
                                let raw = toolArgs[index] ?? "{}"
                                let arguments = (try? JSONValue.parse(Data(raw.utf8))) ?? .object([:])
                                continuation.yield(.toolCall(ToolCall(id: toolIDs[index] ?? "",
                                                                      name: name,
                                                                      arguments: arguments)))
                            }
                        case "message_delta":
                            if let out = json["usage"]?["output_tokens"]?.intValue {
                                usage.outputTokens = out
                            }
                        default:
                            break
                        }
                    }
                    continuation.yield(.done(usage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    func listModels() async throws -> [ModelInfo] {
        let json = try await http.getJSON(baseURL.appendingPathComponent("models"), headers: headers)
        return (json["data"]?.arrayValue ?? []).compactMap { model in
            guard let id = model["id"]?.stringValue else { return nil }
            return ModelInfo(id: id, displayName: model["display_name"]?.stringValue ?? id)
        }
    }
}
