import XCTest
@testable import OpenAvatar

/// Shared contract-test suite (spec Phase 2): the same neutral request must
/// map to each provider's wire format, and each provider's canned response
/// must decode to the same normalized LLMResponse shape, including tool-call
/// round-trips.
final class LLMContractTests: XCTestCase {

    private var request: LLMRequest {
        LLMRequest(
            model: "test-model",
            system: "You are a test.",
            messages: [ChatMessage(role: .user, content: "Hello")],
            tools: [ToolSpec(name: "report_decisions",
                             description: "Report decisions",
                             parameters: .object(["type": "object",
                                                  "properties": .object([:])]))],
            toolChoice: .required,
            maxTokens: 512,
            temperature: 0.2)
    }

    // MARK: Anthropic

    func testAnthropicRequestEncoding() {
        let body = AnthropicProvider.encode(request)
        XCTAssertEqual(body["model"]?.stringValue, "test-model")
        XCTAssertEqual(body["system"]?.stringValue, "You are a test.")
        XCTAssertEqual(body["max_tokens"]?.intValue, 512)
        XCTAssertEqual(body["tools"]?[0]?["name"]?.stringValue, "report_decisions")
        XCTAssertNotNil(body["tools"]?[0]?["input_schema"])
        XCTAssertEqual(body["tool_choice"]?["type"]?.stringValue, "any")
        XCTAssertEqual(body["messages"]?.arrayValue?.count, 1)
        XCTAssertEqual(body["messages"]?[0]?["role"]?.stringValue, "user")
    }

    func testAnthropicResponseDecoding() throws {
        let json = try JSONValue.parse("""
        {"model":"test-model","content":[
           {"type":"text","text":"Sure."},
           {"type":"tool_use","id":"tu_1","name":"report_decisions","input":{"decisions":[]}}],
         "usage":{"input_tokens":10,"output_tokens":20}}
        """)
        let response = try AnthropicProvider.decode(json)
        XCTAssertEqual(response.text, "Sure.")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].name, "report_decisions")
        XCTAssertEqual(response.toolCalls[0].id, "tu_1")
        XCTAssertEqual(response.usage.inputTokens, 10)
        XCTAssertEqual(response.usage.outputTokens, 20)
    }

    // MARK: OpenAI

    func testOpenAIRequestEncoding() {
        let body = OpenAIProvider.encode(request)
        XCTAssertEqual(body["model"]?.stringValue, "test-model")
        // System prompt becomes the first message.
        XCTAssertEqual(body["messages"]?[0]?["role"]?.stringValue, "system")
        XCTAssertEqual(body["messages"]?[1]?["role"]?.stringValue, "user")
        XCTAssertEqual(body["tools"]?[0]?["type"]?.stringValue, "function")
        XCTAssertEqual(body["tools"]?[0]?["function"]?["name"]?.stringValue, "report_decisions")
        XCTAssertEqual(body["tool_choice"]?.stringValue, "required")
    }

    func testOpenAIResponseDecoding() throws {
        let json = try JSONValue.parse("""
        {"model":"test-model","choices":[{"message":{
           "content":null,
           "tool_calls":[{"id":"call_1","type":"function",
             "function":{"name":"report_decisions","arguments":"{\\"decisions\\":[]}"}}]}}],
         "usage":{"prompt_tokens":5,"completion_tokens":7}}
        """)
        let response = try OpenAIProvider.decode(json)
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].name, "report_decisions")
        XCTAssertNotNil(response.toolCalls[0].arguments["decisions"])
        XCTAssertEqual(response.usage.inputTokens, 5)
    }

    // MARK: Gemini

    func testGeminiRequestEncoding() {
        let body = GeminiProvider.encode(request)
        XCTAssertEqual(body["systemInstruction"]?["parts"]?[0]?["text"]?.stringValue, "You are a test.")
        XCTAssertEqual(body["contents"]?[0]?["role"]?.stringValue, "user")
        XCTAssertEqual(body["tools"]?[0]?["functionDeclarations"]?[0]?["name"]?.stringValue,
                       "report_decisions")
        XCTAssertEqual(body["toolConfig"]?["functionCallingConfig"]?["mode"]?.stringValue, "ANY")
        XCTAssertEqual(body["generationConfig"]?["maxOutputTokens"]?.intValue, 512)
    }

    func testGeminiResponseDecoding() throws {
        let json = try JSONValue.parse("""
        {"candidates":[{"content":{"parts":[
           {"functionCall":{"name":"report_decisions","args":{"decisions":[]}}}]}}],
         "usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":4}}
        """)
        let response = try GeminiProvider.decode(json, model: "test-model")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].name, "report_decisions")
        XCTAssertEqual(response.usage.outputTokens, 4)
        XCTAssertEqual(response.model, "test-model")
    }

    // MARK: Ollama

    func testOllamaRequestEncoding() {
        let body = OllamaProvider.encode(request)
        XCTAssertEqual(body["model"]?.stringValue, "test-model")
        XCTAssertEqual(body["stream"]?.boolValue, false)
        XCTAssertEqual(body["messages"]?[0]?["role"]?.stringValue, "system")
        XCTAssertEqual(body["tools"]?[0]?["function"]?["name"]?.stringValue, "report_decisions")
    }

    func testOllamaResponseDecoding() throws {
        let json = try JSONValue.parse("""
        {"message":{"content":"","tool_calls":[
           {"function":{"name":"report_decisions","arguments":{"decisions":[]}}}]},
         "prompt_eval_count":8,"eval_count":9}
        """)
        let response = try OllamaProvider.decode(json, model: "test-model")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.usage.inputTokens, 8)
        XCTAssertEqual(response.usage.outputTokens, 9)
    }

    // MARK: Temperature handling (newer Claude models 400 if it is sent)

    func testTemperatureOmittedByDefaultOnAllProviders() {
        let req = LLMRequest(model: "m",
                             messages: [ChatMessage(role: .user, content: "hi")])
        XCTAssertNil(AnthropicProvider.encode(req)["temperature"])
        XCTAssertNil(OpenAIProvider.encode(req)["temperature"])
        XCTAssertNil(GeminiProvider.encode(req)["generationConfig"]?["temperature"])
        XCTAssertNil(OllamaProvider.encode(req)["options"]?["temperature"])
    }

    func testTemperatureIncludedWhenExplicitlySet() {
        XCTAssertEqual(AnthropicProvider.encode(request)["temperature"]?.numberValue, 0.2)
        XCTAssertEqual(OpenAIProvider.encode(request)["temperature"]?.numberValue, 0.2)
        XCTAssertEqual(GeminiProvider.encode(request)["generationConfig"]?["temperature"]?.numberValue, 0.2)
        XCTAssertEqual(OllamaProvider.encode(request)["options"]?["temperature"]?.numberValue, 0.2)
    }

    // MARK: Cross-provider invariant

    func testAllProvidersProduceIdenticalNormalizedToolCall() throws {
        let anthropic = try AnthropicProvider.decode(try JSONValue.parse(
            #"{"content":[{"type":"tool_use","id":"1","name":"t","input":{"a":1}}],"usage":{}}"#))
        let openai = try OpenAIProvider.decode(try JSONValue.parse(
            #"{"choices":[{"message":{"tool_calls":[{"id":"1","function":{"name":"t","arguments":"{\"a\":1}"}}]}}]}"#))
        let gemini = try GeminiProvider.decode(try JSONValue.parse(
            #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"t","args":{"a":1}}}]}}]}"#), model: "m")
        let ollama = try OllamaProvider.decode(try JSONValue.parse(
            #"{"message":{"content":"","tool_calls":[{"function":{"name":"t","arguments":{"a":1}}}]}}"#), model: "m")

        for response in [anthropic, openai, gemini, ollama] {
            XCTAssertEqual(response.toolCalls.first?.name, "t")
            XCTAssertEqual(response.toolCalls.first?.arguments["a"]?.intValue, 1)
        }
    }
}
