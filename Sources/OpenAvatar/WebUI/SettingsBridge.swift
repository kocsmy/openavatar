import Foundation
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

/// The JSON method router behind the web settings window (the shadcn UI
/// experiment). Each method mirrors what the native SwiftUI settings tabs did
/// — the web page is a rendering swap, not a behavior change. The TypeScript
/// side of this contract lives in web/src/lib/types.ts; keep the two in sync.
@MainActor
final class SettingsBridge {
    private let app = AppState.shared
    private let settings = SettingsStore.shared

    // Setup services live as long as the settings window: their phase is the
    // progress the web page polls while a download/install runs.
    private let whisperSetup = WhisperSetupService()
    private let qwenSetup = QwenSetupService()

    // MARK: Dispatch

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "settings.snapshot": return snapshot()
        case "settings.set": return try setSetting(params)
        case "secrets.save": return try saveSecret(params)
        case "secrets.saveDynamic": return try saveDynamicSecret(params)
        case "routes.set": return try setRoute(params)
        case "routes.test": return await testRoutes()
        case "models.list": return try await listModels(params)
        case "usage.recent": return usage()
        case "transcription.status": return transcriptionStatus()
        case "transcription.setupWhisper": return setupWhisper(params)
        case "transcription.prepareParakeet": app.prepareParakeet(); return .object([:])
        case "transcription.setupQwen":
            Task { await qwenSetup.run(settings: settings) }
            return .object([:])
        case "integrations.known": return knownIntegrations()
        case "integrations.check": return try await checkIntegration(params)
        case "integrations.checkAll": return await checkAllIntegrations()
        case "mcp.add": return try addMCPServer(params)
        case "mcp.remove": return try removeMCPServer(params)
        case "calendar.connect": return await connectCalendar()
        case "calendar.disconnect":
            await GoogleOAuth.shared.disconnect()
            settings.calendarEnabled = false
            return .object([:])
        case "calendar.test": return await testCalendar()
        case "calendar.calendars": return try await listCalendars()
        case "trust.rows": return trustRows()
        case "trust.set": return try setTrust(params)
        case "memory.facts": return memoryFacts()
        case "memory.retire": return try retireFact(params)
        case "memory.wipe": return try wipeMemory()
        case "errors.recent": return errors()
        case "errors.clear": app.clearErrors(); return .object([:])
        case "data.export": return exportData()
        case "data.eraseAll": try app.store.deleteAllData(); return .object([:])
        case "app.checkUpdates": UpdateManager.shared.checkForUpdates(); return .object([:])
        case "app.rerunOnboarding":
#if canImport(AppKit)
            WindowManager.shared.showOnboarding()
#endif
            return .object([:])
        case "app.openURL": return openURL(params)
        case "app.openManifestsFolder":
#if canImport(AppKit)
            NSWorkspace.shared.open(IntegrationRegistry.manifestsDirectory)
#endif
            return .object([:])
        default:
            throw AppError.integration("Unknown bridge method: \(method)")
        }
    }

    // MARK: Snapshot

    private func snapshot() -> JSONValue {
        var s: [String: JSONValue] = [:]
        s["assistantName"] = .string(settings.assistantName)
        s["userDisplayName"] = .string(settings.userDisplayName)
        s["mode"] = .string(settings.mode.rawValue)
        s["autoStartOnCall"] = .bool(settings.autoStartOnCall)
        s["meetingPromptEnabled"] = .bool(settings.meetingPromptEnabled)
        s["confidenceThreshold"] = .number(settings.confidenceThreshold)
        s["transcriptionMode"] = .string(settings.transcriptionMode.rawValue)
        s["whisperCLIPath"] = .string(settings.whisperCLIPath)
        s["whisperModelPath"] = .string(settings.whisperModelPath)
        s["cloudSTTBaseURL"] = .string(settings.cloudSTTBaseURL)
        s["cloudSTTModel"] = .string(settings.cloudSTTModel)
        s["transcriptionLanguage"] = .string(settings.transcriptionLanguage)
        s["diarizationEnabled"] = .bool(settings.diarizationEnabled)
        s["customVocabulary"] = .string(settings.customVocabulary)
        s["openAIBaseURL"] = .string(settings.openAIBaseURL)
        s["ollamaBaseURL"] = .string(settings.ollamaBaseURL)
        s["emailBackend"] = .string(settings.emailBackend.rawValue)
        s["smtpHost"] = .string(settings.smtpHost)
        s["smtpUsername"] = .string(settings.smtpUsername)
        s["emailFromAddress"] = .string(settings.emailFromAddress)
        s["googleClientID"] = .string(settings.googleClientID)
        s["calendarEnabled"] = .bool(settings.calendarEnabled)
        s["calendarSelfEmail"] = .string(settings.calendarSelfEmail)
        s["calendarID"] = .string(settings.calendarID)
        s["githubDefaultRepo"] = .string(settings.githubDefaultRepo)
        s["linearTeamKey"] = .string(settings.linearTeamKey)
        s["slackDefaultChannel"] = .string(settings.slackDefaultChannel)

        var secrets: [String: JSONValue] = [:]
        for (name, key) in Self.secretKeys {
            secrets[name] = .bool(KeychainStore.shared.get(key) != nil)
        }

        var routes: [String: JSONValue] = [:]
        for (task, route) in settings.routes {
            routes[task.rawValue] = .object([
                "provider": .string(route.provider.rawValue),
                "model": .string(route.model)
            ])
        }

        return .object([
            "settings": .object(s),
            "secrets": .object(secrets),
            "routes": .object(routes),
            "version": .string(UpdateManager.shared.currentVersion),
            "dbPath": .string(AppPaths.database.path),
            "calendar": .object([
                "hasBuiltInClient": .bool(GoogleOAuth.shared.hasBuiltInClient),
                "connected": .bool(GoogleOAuth.shared.isConnected)
            ]),
            "languages": .array(TranscriptionLanguage.options.map {
                .object(["code": .string($0.code), "label": .string($0.label)])
            })
        ])
    }

    // MARK: Settings writes

    /// Typed assignment per key — the web side never writes UserDefaults
    /// directly, so every write keeps the SettingsStore didSet side effects.
    private func setSetting(_ params: JSONValue) throws -> JSONValue {
        guard let key = params["key"]?.stringValue else {
            throw AppError.parsing("settings.set needs a key")
        }
        let value = params["value"] ?? .null
        switch key {
        case "assistantName": settings.assistantName = value.stringValue ?? settings.assistantName
        case "userDisplayName": settings.userDisplayName = value.stringValue ?? settings.userDisplayName
        case "mode": settings.mode = AssistantMode(rawValue: value.stringValue ?? "") ?? settings.mode
        case "autoStartOnCall": settings.autoStartOnCall = value.boolValue ?? settings.autoStartOnCall
        case "meetingPromptEnabled": settings.meetingPromptEnabled = value.boolValue ?? settings.meetingPromptEnabled
        case "confidenceThreshold": settings.confidenceThreshold = value.doubleValue ?? settings.confidenceThreshold
        case "transcriptionMode":
            settings.transcriptionMode = TranscriptionMode(rawValue: value.stringValue ?? "") ?? settings.transcriptionMode
        case "whisperCLIPath": settings.whisperCLIPath = value.stringValue ?? settings.whisperCLIPath
        case "whisperModelPath": settings.whisperModelPath = value.stringValue ?? settings.whisperModelPath
        case "cloudSTTBaseURL": settings.cloudSTTBaseURL = value.stringValue ?? settings.cloudSTTBaseURL
        case "cloudSTTModel": settings.cloudSTTModel = value.stringValue ?? settings.cloudSTTModel
        case "transcriptionLanguage": settings.transcriptionLanguage = value.stringValue ?? settings.transcriptionLanguage
        case "diarizationEnabled": settings.diarizationEnabled = value.boolValue ?? settings.diarizationEnabled
        case "customVocabulary": settings.customVocabulary = value.stringValue ?? settings.customVocabulary
        case "openAIBaseURL": settings.openAIBaseURL = value.stringValue ?? settings.openAIBaseURL
        case "ollamaBaseURL": settings.ollamaBaseURL = value.stringValue ?? settings.ollamaBaseURL
        case "emailBackend": settings.emailBackend = EmailBackend(rawValue: value.stringValue ?? "") ?? settings.emailBackend
        case "smtpHost": settings.smtpHost = value.stringValue ?? settings.smtpHost
        case "smtpUsername": settings.smtpUsername = value.stringValue ?? settings.smtpUsername
        case "emailFromAddress": settings.emailFromAddress = value.stringValue ?? settings.emailFromAddress
        case "googleClientID": settings.googleClientID = value.stringValue ?? settings.googleClientID
        case "calendarEnabled": settings.calendarEnabled = value.boolValue ?? settings.calendarEnabled
        case "calendarSelfEmail": settings.calendarSelfEmail = value.stringValue ?? settings.calendarSelfEmail
        case "calendarID":
            settings.calendarID = value.stringValue ?? settings.calendarID
            // Same as the native picker: repoint event lookups immediately.
            app.refreshCalendar()
            app.refreshUpcomingEvents()
        case "githubDefaultRepo": settings.githubDefaultRepo = value.stringValue ?? settings.githubDefaultRepo
        case "linearTeamKey": settings.linearTeamKey = value.stringValue ?? settings.linearTeamKey
        case "slackDefaultChannel": settings.slackDefaultChannel = value.stringValue ?? settings.slackDefaultChannel
        default:
            throw AppError.parsing("Unknown setting key: \(key)")
        }
        return .object([:])
    }

    // MARK: Secrets

    static let secretKeys: [(name: String, key: KeychainStore.Key)] = [
        ("anthropic", .anthropicAPIKey),
        ("openai", .openAIAPIKey),
        ("gemini", .geminiAPIKey),
        ("cloudSTT", .cloudSTTAPIKey),
        ("github", .githubToken),
        ("slack", .slackUserToken),
        ("linear", .linearAPIKey),
        ("smtp", .smtpPassword),
        ("gmail", .gmailAccessToken),
        ("googleClientSecret", .googleClientSecret)
    ]

    private func saveSecret(_ params: JSONValue) throws -> JSONValue {
        guard let name = params["key"]?.stringValue,
              let value = params["value"]?.stringValue, !value.isEmpty,
              let key = Self.secretKeys.first(where: { $0.name == name })?.key else {
            throw AppError.parsing("secrets.save needs a known key and a value")
        }
        KeychainStore.shared.set(value, for: key)
        return .object([:])
    }

    private func saveDynamicSecret(_ params: JSONValue) throws -> JSONValue {
        guard let id = params["integrationID"]?.stringValue,
              let value = params["value"]?.stringValue, !value.isEmpty else {
            throw AppError.parsing("secrets.saveDynamic needs integrationID and value")
        }
        KeychainStore.shared.setSecret(value, forIntegration: id)
        return .object([:])
    }

    // MARK: Models & routing

    private func setRoute(_ params: JSONValue) throws -> JSONValue {
        guard let taskRaw = params["task"]?.stringValue,
              let task = LLMTask(rawValue: taskRaw) else {
            throw AppError.parsing("routes.set needs a task")
        }
        if let providerRaw = params["provider"]?.stringValue,
           let provider = ProviderID(rawValue: providerRaw) {
            settings.routes[task] = ModelRoute(provider: provider,
                                               model: params["model"]?.stringValue ?? "")
        } else {
            settings.routes.removeValue(forKey: task)
        }
        return .object([:])
    }

    private func listModels(_ params: JSONValue) async throws -> JSONValue {
        guard let raw = params["provider"]?.stringValue,
              let provider = ProviderID(rawValue: raw) else {
            throw AppError.parsing("models.list needs a provider")
        }
        let models = try await app.router.listModels(provider: provider)
        return .object(["models": .array(models.map {
            .object(["id": .string($0.id), "displayName": .string($0.displayName)])
        })])
    }

    /// End-to-end verification, same as the native tab: a tiny real completion
    /// through each configured route, full error surfaced on failure.
    private func testRoutes() async -> JSONValue {
        var results: [JSONValue] = []
        for task in LLMTask.allCases {
            let ok: Bool
            let message: String
            if settings.routes[task] == nil {
                ok = false
                message = "no model configured"
            } else {
                do {
                    let response = try await app.router.complete(task: task, LLMRequest(
                        model: "",
                        messages: [ChatMessage(role: .user, content: "Reply with exactly: OK")],
                        maxTokens: 16))
                    ok = true
                    message = "✓ \(response.model): \(response.text.prefix(40))"
                } catch {
                    ok = false
                    message = Redactor.redact(error.localizedDescription)
                }
            }
            results.append(.object([
                "task": .string(task.rawValue), "ok": .bool(ok), "message": .string(message)
            ]))
        }
        return .object(["results": .array(results)])
    }

    private func usage() -> JSONValue {
        let rows = (try? app.store.usageByTask(sinceDays: 7)) ?? []
        return .object(["rows": .array(rows.map { row in
            .object([
                "task": .string(row.task),
                "displayName": .string(LLMTask(rawValue: row.task)?.displayName ?? row.task),
                "calls": .number(Double(row.calls)),
                "inputTokens": .number(Double(row.inputTokens)),
                "outputTokens": .number(Double(row.outputTokens)),
                "cacheReadTokens": .number(Double(row.cacheReadTokens))
            ])
        })])
    }

    // MARK: Transcription engines

    private func transcriptionStatus() -> JSONValue {
        // Mirror the native tab's onAppear: an idle state may just mean nobody
        // looked yet — models could already be on disk from a previous run.
        if case .idle = app.parakeetState { app.refreshParakeetState() }

        let parakeet: (String, String)
        switch app.parakeetState {
        case .idle: parakeet = ("idle", "")
        case .preparing: parakeet = ("preparing", "")
        case .ready: parakeet = ("ready", "")
        case .failed(let message): parakeet = ("failed", message)
        }

        let whisperPhase: (String, String)
        switch whisperSetup.phase {
        case .idle: whisperPhase = ("idle", "")
        case .checking: whisperPhase = ("busy", "Checking what's installed…")
        case .installingCLI: whisperPhase = ("busy", "Installing whisper-cpp via Homebrew (can take a few minutes)…")
        case .downloadingModel(let model): whisperPhase = ("busy", "Downloading \(model.shortName) model (\(model.sizeLabel))…")
        case .done(let message): whisperPhase = ("done", message)
        case .failed(let message): whisperPhase = ("failed", message)
        }

        let qwenPhase: (String, String)
        switch qwenSetup.phase {
        case .idle: qwenPhase = ("idle", "")
        case .installingUV: qwenPhase = ("busy", "Installing uv via Homebrew…")
        case .downloadingRuntime: qwenPhase = ("busy", "Downloading the MLX bridge runtime…")
        case .preparingModel: qwenPhase = ("busy", "First start: installing the Python environment and downloading the model (~3.4 GB) — this can take a while…")
        case .done(let message): qwenPhase = ("done", message)
        case .failed(let message): qwenPhase = ("failed", message)
        }

        return .object([
            "parakeet": .object(["state": .string(parakeet.0), "message": .string(parakeet.1)]),
            "whisper": .object([
                "ready": .bool(WhisperSetupService.isReady(settings: settings)),
                "activeModel": .string(URL(fileURLWithPath: settings.whisperModelPath).lastPathComponent),
                "phase": .string(whisperPhase.0),
                "message": .string(whisperPhase.1)
            ]),
            "qwen": .object([
                "runtimeInstalled": .bool(QwenSetupService.runtimeInstalled),
                "phase": .string(qwenPhase.0),
                "message": .string(qwenPhase.1)
            ])
        ])
    }

    /// Kick off (or re-check) whisper setup; the web page polls status.
    private func setupWhisper(_ params: JSONValue) -> JSONValue {
        let model: WhisperModel? = switch params["model"]?.stringValue {
        case "base": .base
        case "small": .small
        case "medium": .medium
        case "largeTurbo": .largeTurbo
        default: nil
        }
        guard !whisperSetup.isBusy else { return .object([:]) }
        Task { await whisperSetup.run(settings: settings, model: model) }
        return .object([:])
    }

    // MARK: Integrations

    private func knownIntegrations() -> JSONValue {
        let manifests = IntegrationRegistry.shared.known()
            .filter { $0.kind == .manifest }
            .map { entry in
                JSONValue.object([
                    "id": .string(entry.id.rawValue),
                    "displayName": .string(entry.id.displayName),
                    "configured": .bool(entry.configured),
                    "authHint": .string(entry.authHint ?? "")
                ])
            }
        let servers = MCPServerConfig.loadAll().map { server in
            JSONValue.object([
                "id": .string(server.id),
                "name": .string(server.name),
                "command": .string(server.command)
            ])
        }
        return .object(["manifests": .array(manifests), "mcpServers": .array(servers)])
    }

    private func checkIntegration(_ params: JSONValue) async throws -> JSONValue {
        guard let id = params["id"]?.stringValue else {
            throw AppError.parsing("integrations.check needs an id")
        }
        let health: IntegrationHealth
        if let integration = await app.executor.integrations()[IntegrationID(id)] {
            health = await integration.healthCheck()
        } else {
            health = IntegrationHealth(ok: false, message: "Not configured yet")
        }
        return .object([
            "id": .string(id), "ok": .bool(health.ok),
            "message": .string(Redactor.redact(health.message))
        ])
    }

    private func checkAllIntegrations() async -> JSONValue {
        let checks = await app.executor.healthChecks()
        let results = checks.sorted { $0.key.rawValue < $1.key.rawValue }.map { id, health in
            JSONValue.object([
                "id": .string(id.rawValue), "ok": .bool(health.ok),
                "message": .string(Redactor.redact(health.message))
            ])
        }
        return .object(["results": .array(results)])
    }

    private func addMCPServer(_ params: JSONValue) throws -> JSONValue {
        guard let name = params["name"]?.stringValue, !name.isEmpty,
              let command = params["command"]?.stringValue, !command.isEmpty else {
            throw AppError.parsing("mcp.add needs name and command")
        }
        var servers = MCPServerConfig.loadAll()
        let id = name.lowercased().replacingOccurrences(of: " ", with: "-")
        servers.append(MCPServerConfig(id: id, name: name, command: command))
        MCPServerConfig.saveAll(servers)
        return knownIntegrations()
    }

    private func removeMCPServer(_ params: JSONValue) throws -> JSONValue {
        guard let id = params["id"]?.stringValue else {
            throw AppError.parsing("mcp.remove needs an id")
        }
        var servers = MCPServerConfig.loadAll()
        servers.removeAll { $0.id == id }
        MCPServerConfig.saveAll(servers)
        return knownIntegrations()
    }

    // MARK: Google Calendar

    private func connectCalendar() async -> JSONValue {
        do {
            try await GoogleOAuth.shared.connect()
            settings.calendarEnabled = true   // connecting implies you want it used
            return .object([
                "connected": .bool(true),
                "message": .string("Connected. Calendar look-up is ready.")
            ])
        } catch {
            return .object([
                "connected": .bool(false),
                "message": .string(Redactor.redact(error.localizedDescription))
            ])
        }
    }

    private func testCalendar() async -> JSONValue {
        do {
            let client = GoogleCalendarClient(
                tokenProvider: { try await GoogleOAuth.shared.accessToken() })
            if let event = try await client.currentEvent(calendarID: settings.calendarID) {
                let names = event.others(excludingSelfEmail: settings.calendarSelfEmail)
                    .map(\.name).joined(separator: ", ")
                return .object(["message": .string(
                    "“\(event.title)” — \(names.isEmpty ? "no other attendees" : names)")])
            }
            return .object(["message": .string("No event scheduled around now.")])
        } catch {
            return .object(["message": .string(Redactor.redact(error.localizedDescription))])
        }
    }

    private func listCalendars() async throws -> JSONValue {
        let client = GoogleCalendarClient(
            tokenProvider: { try await GoogleOAuth.shared.accessToken() })
        let calendars = (try? await client.listCalendars()) ?? []
        return .object(["calendars": .array(calendars.map {
            .object(["id": .string($0.id), "name": .string($0.name), "isPrimary": .bool($0.isPrimary)])
        })])
    }

    // MARK: Trust matrix

    /// Curated native tools (kept in sync with the executors), then dynamic
    /// rows from manifests/MCP servers.
    static let nativeTrustRows: [(qualified: String, risk: RiskClass)] = [
        ("github.create_branch", .write),
        ("github.commit_changes", .write),
        ("github.open_pr", .write),
        ("github.comment_on_pr", .write),
        ("github.merge_pr", .destructive),
        ("github.revert_pr", .write),
        ("slack.post_message", .write),
        ("slack.post_thread_reply", .write),
        ("slack.send_dm", .write),
        ("linear.create_issue", .write),
        ("linear.update_issue", .write),
        ("linear.comment_on_issue", .write),
        ("linear.assign_issue", .write),
        ("email.draft_email", .draft),
        ("email.send_email", .destructive)
    ]

    private func trustRows() -> JSONValue {
        func row(_ qualified: String, _ risk: RiskClass, dynamic: Bool) -> JSONValue {
            .object([
                "tool": .string(qualified),
                "risk": .string(risk.rawValue),
                "graduated": .bool(app.trust.canGraduate(qualifiedTool: qualified, riskClass: risk)),
                "dynamic": .bool(dynamic),
                "passive": .string(settings.trustMatrix.setting(for: qualified, mode: .passive).rawValue),
                "active": .string(settings.trustMatrix.setting(for: qualified, mode: .active).rawValue)
            ])
        }
        var rows = Self.nativeTrustRows.map { row($0.qualified, $0.risk, dynamic: false) }
        rows += IntegrationRegistry.shared.dynamicTrustRows().map { row($0.qualified, $0.risk, dynamic: true) }
        return .object([
            "graduationThreshold": .number(Double(TrustPolicyEngine.graduationThreshold)),
            "rows": .array(rows)
        ])
    }

    private func setTrust(_ params: JSONValue) throws -> JSONValue {
        guard let tool = params["tool"]?.stringValue,
              let mode = AssistantMode(rawValue: params["mode"]?.stringValue ?? ""),
              let setting = TrustSetting(rawValue: params["setting"]?.stringValue ?? "") else {
            throw AppError.parsing("trust.set needs tool, mode, setting")
        }
        // Explicit user action is the only path that changes trust (spec §5.4).
        var matrix = settings.trustMatrix
        matrix.set(setting, for: tool, mode: mode)
        settings.trustMatrix = matrix
        return .object([:])
    }

    // MARK: Memory

    private func memoryFacts() -> JSONValue {
        let facts = (try? app.store.activeFacts()) ?? []
        let digests = (try? app.store.recentDigests(limit: 5)) ?? []
        return .object([
            "facts": .array(facts.map { fact in
                .object([
                    "id": .string(fact.id.uuidString),
                    "category": .string(fact.category.rawValue),
                    "content": .string(fact.content),
                    "salience": .number(fact.salience),
                    "lastReinforced": .string(
                        fact.lastReinforcedAt.formatted(date: .abbreviated, time: .omitted))
                ])
            }),
            "digests": .array(digests.map { .string($0) })
        ])
    }

    private func retireFact(_ params: JSONValue) throws -> JSONValue {
        guard let id = params["id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            throw AppError.parsing("memory.retire needs a fact id")
        }
        try app.store.retireFact(id: id)
        return .object([:])
    }

    private func wipeMemory() throws -> JSONValue {
        for fact in (try? app.store.activeFacts()) ?? [] {
            try? app.store.retireFact(id: fact.id)
        }
        return .object([:])
    }

    // MARK: Data & diagnostics

    private func errors() -> JSONValue {
        .object(["errors": .array(app.errorLog.map { entry in
            .object([
                "at": .string(entry.at.formatted(date: .omitted, time: .standard)),
                "message": .string(entry.message)
            ])
        })])
    }

    private func exportData() -> JSONValue {
#if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "openavatar-export.json"
        guard panel.runModal() == .OK, let url = panel.url else {
            return .object(["message": .string("")])
        }
        do {
            try app.store.exportAllJSON().write(to: url)
            return .object(["message": .string("Exported to \(url.path)")])
        } catch {
            return .object(["message": .string("Export failed: \(error.localizedDescription)")])
        }
#else
        return .object(["message": .string("Export needs macOS")])
#endif
    }

    private func openURL(_ params: JSONValue) -> JSONValue {
        // Web content never opens URLs itself; only plain web links pass here.
        guard let raw = params["url"]?.stringValue, let url = URL(string: raw),
              url.scheme == "https" || url.scheme == "http" else {
            return .object([:])
        }
#if canImport(AppKit)
        NSWorkspace.shared.open(url)
#endif
        return .object([:])
    }
}
