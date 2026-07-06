import XCTest
@testable import OpenAvatar

/// Improvement #2 — the declarative integration engine and MCP adapter.
final class IntegrationEngineTests: XCTestCase {

    // MARK: Manifest parsing & validation

    func testBuiltinManifestsParseAndValidate() throws {
        for json in BuiltinManifests.all {
            let manifest = try IntegrationManifest.load(from: Data(json.utf8))
            XCTAssertFalse(manifest.tools.isEmpty)
        }
    }

    func testManifestRejectsBuiltinIDCollision() {
        let json = """
        {"id":"github","name":"X","baseURL":"https://x.dev","auth":{"kind":"none"},
         "tools":[{"name":"t","description":"d","riskClass":"write",
                   "parameters":{"type":"object"},
                   "request":{"method":"POST","path":"/t"}}]}
        """
        XCTAssertThrowsError(try IntegrationManifest.load(from: Data(json.utf8)))
    }

    func testManifestRejectsBadRiskClass() {
        let json = """
        {"id":"x","name":"X","baseURL":"https://x.dev","auth":{"kind":"none"},
         "tools":[{"name":"t","description":"d","riskClass":"yolo",
                   "parameters":{"type":"object"},
                   "request":{"method":"POST","path":"/t"}}]}
        """
        XCTAssertThrowsError(try IntegrationManifest.load(from: Data(json.utf8)))
    }

    // MARK: Template engine

    func testStringTemplateRendering() {
        let args: JSONValue = .object(["name": "world", "count": .number(3)])
        XCTAssertEqual(TemplateEngine.render("hello {{name}} x{{count}}", arguments: args),
                       "hello world x3")
    }

    func testBodyTemplatePreservesTypesAndDropsMissingOptionals() {
        let template: JSONValue = .object([
            "title": "{{title}}",
            "count": "{{count}}",
            "missing": "{{nope}}",
            "nested": .object(["inner": "prefix-{{title}}"])
        ])
        let args: JSONValue = .object(["title": "Hi", "count": .number(7)])
        let rendered = TemplateEngine.renderBody(template, arguments: args)
        XCTAssertEqual(rendered["title"]?.stringValue, "Hi")
        XCTAssertEqual(rendered["count"]?.numberValue, 7)   // stays a number
        XCTAssertNil(rendered["missing"])                    // dropped, not ""
        XCTAssertEqual(rendered["nested"]?["inner"]?.stringValue, "prefix-Hi")
    }

    func testJSONPointerResolution() throws {
        let doc = try JSONValue.parse(#"{"a":[{"b":"deep"}],"url":"https://x"}"#)
        XCTAssertEqual(TemplateEngine.stringAt(pointer: "/a/0/b", in: doc), "deep")
        XCTAssertEqual(TemplateEngine.stringAt(pointer: "/url", in: doc), "https://x")
        XCTAssertNil(TemplateEngine.stringAt(pointer: "/missing", in: doc))
    }

    func testRevertHandleSubstitution() {
        let handle: JSONValue = .object(["task_id": .string("42")])
        XCTAssertEqual(TemplateEngine.render("/tasks/{{revert.task_id}}",
                                             arguments: .object([:]), revertHandle: handle),
                       "/tasks/42")
    }

    // MARK: 🤖 enforcement in the engine

    func testAttributionAppliedToDeclaredParams() {
        let args: JSONValue = .object(["content": "Ship it", "due_string": "tomorrow"])
        let out = ManifestIntegration.applyAttribution(to: args, params: ["content"])
        XCTAssertEqual(out["content"]?.stringValue, "🤖 Ship it")
        XCTAssertEqual(out["due_string"]?.stringValue, "tomorrow") // untouched
    }

    func testAttributionDefaultsCoverCommonTextParams() {
        let args: JSONValue = .object(["text": "hello", "title": "T", "task_id": "9"])
        let out = ManifestIntegration.applyAttribution(
            to: args, params: ManifestIntegration.defaultAttributedParams)
        XCTAssertEqual(out["text"]?.stringValue, "🤖 hello")
        XCTAssertEqual(out["title"]?.stringValue, "🤖 T")
        XCTAssertEqual(out["task_id"]?.stringValue, "9")
    }

    // MARK: Risk defaults

    func testUnknownManifestToolIsDestructive() throws {
        let manifest = try IntegrationManifest.load(from: Data(BuiltinManifests.todoist.utf8))
        let integration = ManifestIntegration(manifest: manifest, secret: "x")
        XCTAssertEqual(integration.riskClass(for: "create_task"), .write)
        XCTAssertEqual(integration.riskClass(for: "not_declared"), .destructive)
    }

    func testMCPRiskHeuristicEscalatesDestructiveNames() {
        let integration = MCPIntegration(config: MCPServerConfig(id: "x", name: "X", command: "true"))
        XCTAssertEqual(integration.riskClass(for: "delete_page"), .destructive)
        XCTAssertEqual(integration.riskClass(for: "send_invoice"), .destructive)
        XCTAssertEqual(integration.riskClass(for: "create_page"), .write)
    }

    // MARK: MCP result mapping

    func testMCPTextExtraction() throws {
        let result = try JSONValue.parse("""
        {"content":[{"type":"text","text":"line1"},{"type":"image","data":"x"},
                    {"type":"text","text":"line2"}]}
        """)
        XCTAssertEqual(MCPClient.text(from: result), "line1\nline2")
    }

    // MARK: Dynamic IntegrationID

    func testIntegrationIDCodableAsPlainString() throws {
        let id = IntegrationID("mcp-notion")
        let encoded = try JSONEncoder().encode(id)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"mcp-notion\"")
        let decoded = try JSONDecoder().decode(IntegrationID.self, from: encoded)
        XCTAssertEqual(decoded, id)
        XCTAssertEqual(decoded.displayName, "Mcp Notion")
        XCTAssertEqual(IntegrationID.github.displayName, "GitHub")
    }
}
