import Foundation

/// Improvement #2 — declarative integrations. An integration is a JSON file:
/// auth scheme, endpoints, tool schemas, request templates, attribution
/// fields, and optional revert. `ManifestIntegration` interprets it, so adding
/// an integration means dropping a manifest into
/// `~/Library/Application Support/OpenAvatar/integrations/` — no code, no
/// rebuild. This is what lets the catalog grow to hundreds/thousands fast.
struct IntegrationManifest: Codable, Sendable {
    var id: String                 // "todoist" — becomes the IntegrationID
    var name: String               // "Todoist"
    var baseURL: String            // "https://api.todoist.com/rest/v2"
    var auth: Auth
    var healthCheck: HealthCheck?
    var tools: [Tool]

    var integrationID: IntegrationID { IntegrationID(id) }

    struct Auth: Codable, Sendable {
        /// bearer | header | query | none
        var kind: String
        /// For kind=header: the header name (e.g. "X-Api-Key").
        /// For kind=query: the query parameter name (e.g. "key").
        var name: String?
        /// Optional prefix for the credential value (e.g. "Token ").
        var valuePrefix: String?
        /// Shown in Settings next to the secret field.
        var hint: String?
    }

    struct HealthCheck: Codable, Sendable {
        var method: String        // GET/POST
        var path: String          // "/projects"
        /// Optional JSON pointer whose presence marks success, e.g. "/0/id".
        var successPath: String?
    }

    struct Tool: Codable, Sendable {
        var name: String                    // "create_task"
        var description: String
        /// JSON-Schema object for the tool parameters (exposed to the planner).
        var parameters: JSONValue
        /// read | draft | write | destructive
        var riskClass: String
        var request: Request
        /// Parameter names whose string values receive the 🤖 prefix
        /// (attribution is enforced by the engine, not the manifest author's
        /// goodwill — but the author declares WHERE the marker belongs).
        var attributedParams: [String]?
        var response: Response?
        var revert: Request?

        var risk: RiskClass { RiskClass(rawValue: riskClass) ?? .write }
    }

    struct Request: Codable, Sendable {
        var method: String                  // GET/POST/PATCH/PUT/DELETE
        /// Path template with {{param}} placeholders, e.g. "/tasks/{{task_id}}".
        var path: String
        /// Optional JSON body template. String values support {{param}}
        /// substitution; a value of exactly "{{param}}" preserves the
        /// parameter's original JSON type. {{revert.x}} reads revert-handle
        /// fields in revert requests.
        var body: JSONValue?
        /// Query parameters as name → template.
        var query: [String: String]?
    }

    struct Response: Codable, Sendable {
        /// Template for the human-readable result, e.g. "Created task {{response./id}}".
        /// {{response./json/pointer}} reads from the response JSON;
        /// {{param}} reads from the tool arguments.
        var summaryTemplate: String?
        /// JSON pointer to a URL in the response, e.g. "/url".
        var urlPath: String?
        /// revertHandle fields: name → JSON pointer into the response,
        /// e.g. {"task_id": "/id"}.
        var revertHandle: [String: String]?
    }

    // MARK: Validation

    func validate() throws {
        guard !id.isEmpty, id.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil else {
            throw AppError.parsing("Manifest id must be lowercase alphanumeric/dash/underscore: '\(id)'")
        }
        guard IntegrationID.builtin.allSatisfy({ $0.rawValue != id }) else {
            throw AppError.parsing("Manifest id '\(id)' collides with a built-in integration")
        }
        guard URL(string: baseURL) != nil else {
            throw AppError.parsing("Manifest '\(id)': invalid baseURL")
        }
        guard !tools.isEmpty else {
            throw AppError.parsing("Manifest '\(id)': no tools")
        }
        for tool in tools {
            guard RiskClass(rawValue: tool.riskClass) != nil else {
                throw AppError.parsing("Manifest '\(id)': tool '\(tool.name)' has unknown riskClass '\(tool.riskClass)'")
            }
        }
    }

    static func load(from data: Data) throws -> IntegrationManifest {
        let manifest = try JSONDecoder().decode(IntegrationManifest.self, from: data)
        try manifest.validate()
        return manifest
    }
}

// MARK: - Template rendering

enum TemplateEngine {
    /// Renders {{param}} placeholders from tool arguments, {{revert.x}} from a
    /// revert handle, and {{response./json/pointer}} from a response document.
    static func render(_ template: String, arguments: JSONValue,
                       response: JSONValue? = nil, revertHandle: JSONValue? = nil) -> String {
        var out = template
        while let range = out.range(of: "\\{\\{[^}]+\\}\\}", options: .regularExpression) {
            let token = String(out[range].dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespaces)
            let replacement: String
            if token.hasPrefix("response.") {
                let pointer = String(token.dropFirst("response.".count))
                replacement = response.flatMap { stringAt(pointer: pointer, in: $0) } ?? ""
            } else if token.hasPrefix("revert.") {
                let key = String(token.dropFirst("revert.".count))
                replacement = revertHandle?[key].flatMap(stringify) ?? ""
            } else {
                replacement = arguments[token].flatMap(stringify) ?? ""
            }
            out.replaceSubrange(range, with: replacement)
        }
        return out
    }

    /// Renders a JSON body template: string leaves get {{}} substitution; a
    /// leaf that is EXACTLY one placeholder keeps the source JSON type
    /// (numbers stay numbers, arrays stay arrays). Object/array nodes recurse.
    /// Leaves that reference a missing optional parameter are dropped.
    static func renderBody(_ template: JSONValue, arguments: JSONValue,
                           revertHandle: JSONValue? = nil) -> JSONValue {
        switch template {
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for (key, value) in object {
                let rendered = renderBody(value, arguments: arguments, revertHandle: revertHandle)
                if case .null = rendered { continue } // drop unresolved optionals
                out[key] = rendered
            }
            return .object(out)
        case .array(let array):
            return .array(array.map { renderBody($0, arguments: arguments, revertHandle: revertHandle) })
        case .string(let string):
            // Whole-value placeholder → preserve original JSON type.
            if string.hasPrefix("{{"), string.hasSuffix("}}"), !string.dropFirst(2).dropLast(2).contains("{") {
                let token = String(string.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                if token.hasPrefix("revert.") {
                    return revertHandle?[String(token.dropFirst("revert.".count))] ?? .null
                }
                return arguments[token] ?? .null
            }
            return .string(render(string, arguments: arguments, revertHandle: revertHandle))
        default:
            return template
        }
    }

    /// Resolve a JSON pointer ("/a/0/b") in a document.
    static func value(atPointer pointer: String, in document: JSONValue) -> JSONValue? {
        guard pointer.hasPrefix("/") else { return nil }
        var current = document
        for component in pointer.dropFirst().components(separatedBy: "/") where !component.isEmpty {
            if let index = Int(component), let element = current[index] {
                current = element
            } else if let child = current[component] {
                current = child
            } else {
                return nil
            }
        }
        return current
    }

    static func stringAt(pointer: String, in document: JSONValue) -> String? {
        value(atPointer: pointer, in: document).flatMap(stringify)
    }

    private static func stringify(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .number(let n):
            return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        case .null: return nil
        default: return value.encodedString()
        }
    }
}
