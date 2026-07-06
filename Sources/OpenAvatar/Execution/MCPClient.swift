import Foundation

/// A configured MCP server (Model Context Protocol). Any MCP server's tools
/// become executable actions — this is the fastest path to thousands of
/// integrations: the ecosystem ships servers for Notion, Jira, Salesforce,
/// databases, browsers, … and OpenAvatar consumes them all uniformly.
struct MCPServerConfig: Codable, Identifiable, Hashable, Sendable {
    var id: String        // "notion" → IntegrationID "mcp-notion"
    var name: String      // display name
    /// Shell command that launches the server on stdio,
    /// e.g. "npx -y @notionhq/notion-mcp-server".
    var command: String

    var integrationID: IntegrationID { IntegrationID("mcp-\(id)") }

    static func loadAll() -> [MCPServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: "mcpServers"),
              let configs = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return []
        }
        return configs
    }

    static func saveAll(_ configs: [MCPServerConfig]) {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: "mcpServers")
        }
    }
}

/// Minimal MCP client: JSON-RPC 2.0 over stdio (newline-delimited).
/// Supports initialize → tools/list → tools/call, which is all the executor
/// needs. Connections persist per server for the app's lifetime.
actor MCPClient {
    private let config: MCPServerConfig
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var buffer = Data()
    private(set) var initialized = false

    init(config: MCPServerConfig) {
        self.config = config
    }

    // MARK: Lifecycle

    func ensureRunning() async throws {
        if initialized, process?.isRunning == true { return }
        try launch()
        _ = try await request("initialize", params: .object([
            "protocolVersion": "2025-06-18",
            "capabilities": .object([:]),
            "clientInfo": .object(["name": "OpenAvatar", "version": "1.0.0"])
        ]))
        try notify("notifications/initialized", params: .object([:]))
        initialized = true
    }

    private func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", config.command]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
    }

    func shutdown() {
        process?.terminate()
        process = nil
        initialized = false
        for (_, continuation) in pending {
            continuation.resume(throwing: AppError.integration("MCP server \(config.name) shut down"))
        }
        pending.removeAll()
    }

    // MARK: MCP operations

    func listTools() async throws -> [ToolSpec] {
        try await ensureRunning()
        let result = try await request("tools/list", params: .object([:]))
        return (result["tools"]?.arrayValue ?? []).compactMap { tool in
            guard let name = tool["name"]?.stringValue else { return nil }
            return ToolSpec(name: name,
                            description: tool["description"]?.stringValue ?? name,
                            parameters: tool["inputSchema"] ?? .object(["type": "object"]))
        }
    }

    func callTool(name: String, arguments: JSONValue) async throws -> String {
        try await ensureRunning()
        let result = try await request("tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments
        ]))
        if result["isError"]?.boolValue == true {
            throw AppError.integration("MCP \(config.name).\(name) failed: \(Self.text(from: result).prefix(300))")
        }
        return Self.text(from: result)
    }

    static func text(from result: JSONValue) -> String {
        (result["content"]?.arrayValue ?? [])
            .compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
            .joined(separator: "\n")
    }

    // MARK: JSON-RPC plumbing

    private func request(_ method: String, params: JSONValue,
                         timeoutSeconds: UInt64 = 60) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let message: JSONValue = .object(["jsonrpc": "2.0", "id": .number(Double(id)),
                                          "method": .string(method), "params": params])
        try write(message)

        // Timeout watchdog.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            await self?.timeout(id: id)
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
        }
    }

    private func notify(_ method: String, params: JSONValue) throws {
        try write(.object(["jsonrpc": "2.0", "method": .string(method), "params": params]))
    }

    private func write(_ message: JSONValue) throws {
        guard let stdinHandle else {
            throw AppError.integration("MCP server \(config.name) is not running")
        }
        var data = try message.encodedData()
        data.append(0x0A) // newline-delimited
        stdinHandle.write(data)
    }

    private func timeout(id: Int) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: AppError.integration("MCP server \(config.name) timed out"))
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let message = try? JSONValue.parse(line) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSONValue) {
        guard let id = message["id"]?.intValue,
              let continuation = pending.removeValue(forKey: id) else {
            return // notification or unmatched — ignore in v1
        }
        if let error = message["error"] {
            let text = error["message"]?.stringValue ?? "unknown MCP error"
            continuation.resume(throwing: AppError.integration("MCP \(config.name): \(text)"))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }
}

/// Keeps one live client per server across integration-registry rebuilds.
actor MCPConnectionPool {
    static let shared = MCPConnectionPool()
    private var clients: [String: MCPClient] = [:]

    func client(for config: MCPServerConfig) -> MCPClient {
        if let existing = clients[config.id] { return existing }
        let client = MCPClient(config: config)
        clients[config.id] = client
        return client
    }

    func shutdownAll() async {
        for client in clients.values { await client.shutdown() }
        clients.removeAll()
    }
}
