import Foundation

/// Generic executor that turns an `IntegrationManifest` into a live
/// `ActionIntegration`. One engine, unlimited integrations.
///
/// Hard guarantees enforced HERE for every manifest (authors can't opt out):
/// - 🤖 attribution is applied to the declared attributedParams (and when a
///   manifest declares none, to a default set of text-bearing params).
/// - Secrets come from the Keychain, are injected per the auth scheme, and
///   never appear in summaries or errors (Redactor).
struct ManifestIntegration: ActionIntegration {
    let manifest: IntegrationManifest
    let secret: String?
    var http = HTTPClient()

    var id: IntegrationID { manifest.integrationID }

    var toolSpecs: [ToolSpec] {
        manifest.tools.map { tool in
            ToolSpec(name: tool.name, description: tool.description, parameters: tool.parameters)
        }
    }

    func riskClass(for tool: String) -> RiskClass {
        manifest.tools.first { $0.name == tool }?.risk ?? .destructive
    }

    /// Default attribution targets when the manifest doesn't declare any.
    static let defaultAttributedParams = ["text", "body", "message", "title", "content", "comment"]

    // MARK: Execution

    func execute(_ call: ToolCall) async throws -> ActionResult {
        guard let tool = manifest.tools.first(where: { $0.name == call.name }) else {
            throw AppError.integration("\(manifest.name): unknown tool \(call.name)")
        }

        // 🤖 enforcement in the engine (spec §5.3).
        let arguments = Self.applyAttribution(
            to: call.arguments,
            params: tool.attributedParams ?? Self.defaultAttributedParams)

        let (data, _) = try await send(tool.request, arguments: arguments)
        let responseJSON = (try? JSONValue.parse(data)) ?? .null

        var summary = "\(manifest.name): \(call.name) succeeded"
        if let template = tool.response?.summaryTemplate {
            let rendered = TemplateEngine.render(template, arguments: arguments, response: responseJSON)
            if !rendered.isEmpty { summary = rendered }
        }
        var url: String?
        if let urlPath = tool.response?.urlPath {
            url = TemplateEngine.stringAt(pointer: urlPath, in: responseJSON)
        }
        var revertHandle: JSONValue?
        if tool.revert != nil, let mapping = tool.response?.revertHandle {
            var handle: [String: JSONValue] = ["tool": .string(tool.name)]
            for (key, pointer) in mapping {
                handle[key] = TemplateEngine.value(atPointer: pointer, in: responseJSON) ?? .null
            }
            revertHandle = .object(handle)
        }

        return ActionResult(integration: id, tool: call.name,
                            summary: String(Redactor.redact(summary).prefix(300)),
                            url: url, revertHandle: revertHandle)
    }

    func revert(_ result: ActionResult) async throws {
        guard let handle = result.revertHandle,
              let toolName = handle["tool"]?.stringValue,
              let tool = manifest.tools.first(where: { $0.name == toolName }),
              let revertRequest = tool.revert else {
            throw AppError.integration("\(manifest.name) does not support undo for \(result.tool)")
        }
        _ = try await send(revertRequest, arguments: .object([:]), revertHandle: handle)
    }

    func healthCheck() async -> IntegrationHealth {
        guard manifest.auth.kind == "none" || secret != nil else {
            return IntegrationHealth(ok: false, message: "No credential configured")
        }
        guard let check = manifest.healthCheck else {
            return IntegrationHealth(ok: true, message: "Configured (no health endpoint declared)")
        }
        do {
            let request = IntegrationManifest.Request(method: check.method, path: check.path,
                                                      body: nil, query: nil)
            let (data, _) = try await send(request, arguments: .object([:]))
            if let successPath = check.successPath {
                let json = (try? JSONValue.parse(data)) ?? .null
                guard TemplateEngine.value(atPointer: successPath, in: json) != nil else {
                    return IntegrationHealth(ok: false, message: "\(manifest.name): unexpected health response")
                }
            }
            return IntegrationHealth(ok: true, message: "\(manifest.name) reachable and authenticated")
        } catch {
            return IntegrationHealth(ok: false, message: Redactor.redact(error.localizedDescription))
        }
    }

    // MARK: Wire

    private func send(_ request: IntegrationManifest.Request, arguments: JSONValue,
                      revertHandle: JSONValue? = nil) async throws -> (Data, Int) {
        guard let base = URL(string: manifest.baseURL) else {
            throw AppError.notConfigured("\(manifest.name): bad baseURL")
        }
        let path = TemplateEngine.render(request.path, arguments: arguments, revertHandle: revertHandle)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AppError.notConfigured("\(manifest.name): bad baseURL")
        }
        components.path = (components.path + path).replacingOccurrences(of: "//", with: "/")

        var queryItems: [URLQueryItem] = []
        for (name, template) in request.query ?? [:] {
            let value = TemplateEngine.render(template, arguments: arguments, revertHandle: revertHandle)
            if !value.isEmpty { queryItems.append(URLQueryItem(name: name, value: value)) }
        }
        // Auth via query parameter.
        if manifest.auth.kind == "query", let name = manifest.auth.name, let secret {
            queryItems.append(URLQueryItem(name: name, value: (manifest.auth.valuePrefix ?? "") + secret))
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }

        guard let url = components.url else {
            throw AppError.integration("\(manifest.name): could not build URL for \(path)")
        }

        var headers: [String: String] = [:]
        switch manifest.auth.kind {
        case "bearer":
            if let secret { headers["Authorization"] = "Bearer \((manifest.auth.valuePrefix ?? ""))\(secret)" }
        case "header":
            if let name = manifest.auth.name, let secret {
                headers[name] = (manifest.auth.valuePrefix ?? "") + secret
            }
        default:
            break
        }

        var bodyData: Data?
        if let bodyTemplate = request.body {
            let rendered = TemplateEngine.renderBody(bodyTemplate, arguments: arguments,
                                                     revertHandle: revertHandle)
            bodyData = try rendered.encodedData()
        }

        let data = try await http.send(request.method.uppercased(), url,
                                       headers: headers, body: bodyData)
        return (data, 200)
    }

    // MARK: Attribution

    static func applyAttribution(to arguments: JSONValue, params: [String]) -> JSONValue {
        guard var object = arguments.objectValue else { return arguments }
        for param in params {
            if let value = object[param]?.stringValue {
                object[param] = .string(Attribution.prefix(value))
            }
        }
        return .object(object)
    }
}
