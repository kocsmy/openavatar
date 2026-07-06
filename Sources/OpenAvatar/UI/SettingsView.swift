import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionSettingsTab()
                .tabItem { Label("Transcription", systemImage: "waveform") }
            ModelsSettingsTab()
                .tabItem { Label("Models", systemImage: "brain") }
            IntegrationsSettingsTab()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            TrustMatrixTab()
                .tabItem { Label("Trust", systemImage: "checkmark.shield") }
            MemorySettingsTab()
                .tabItem { Label("Memory", systemImage: "brain.head.profile") }
            MetricsDashboardTab()
                .tabItem { Label("Metrics", systemImage: "chart.bar") }
            DataSettingsTab()
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 640, height: 520)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Assistant") {
                TextField("Assistant name (wake phrase)", text: $settings.assistantName)
                Text("In Active mode, say “\(settings.assistantName), …” on a call to trigger immediate execution.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Your name (used in email attribution)", text: $settings.userDisplayName)
            }
            Section("Mode") {
                Picker("Mode", selection: $settings.mode) {
                    ForEach(AssistantMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("Passive: decisions accumulate into a post-call review. Active: executes immediately when you address the assistant directly (subject to the Trust matrix).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Detection") {
                Slider(value: $settings.confidenceThreshold, in: 0.3...0.9, step: 0.05) {
                    Text("Confidence threshold: \(settings.confidenceThreshold, specifier: "%.2f")")
                }
                Text("Decisions below this confidence are greyed out and never auto-executed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Re-run onboarding") {
#if canImport(AppKit)
                    WindowManager.shared.showOnboarding()
#endif
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Transcription

struct TranscriptionSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var sttKey = KeychainStore.shared.get(.cloudSTTAPIKey) ?? ""

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Transcription", selection: $settings.transcriptionMode) {
                    ForEach(TranscriptionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if settings.transcriptionMode == .cloud {
                    Label("Call audio will be sent to the configured cloud provider.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if settings.transcriptionMode == .local {
                Section("whisper.cpp (local, private, offline)") {
                    TextField("whisper-cli path", text: $settings.whisperCLIPath)
                    TextField("Model path (.bin)", text: $settings.whisperModelPath)
                    Text("Install with `brew install whisper-cpp`, then download a model, e.g.:\nhuggingface.co/ggerganov/whisper.cpp → ggml-base.en.bin (bundled default), small/medium for higher accuracy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Cloud STT (OpenAI-compatible, BYO key)") {
                    TextField("Base URL", text: $settings.cloudSTTBaseURL)
                    TextField("Model", text: $settings.cloudSTTModel)
                    SecureField("API key", text: $sttKey)
                        .onChange(of: sttKey) { _, new in
                            KeychainStore.shared.set(new, for: .cloudSTTAPIKey)
                        }
                    Text("Any OpenAI-compatible transcription endpoint works (override the base URL for Deepgram/Groq-style services).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Models (LLM providers + per-task routing)

struct ModelsSettingsTab: View {
    @EnvironmentObject var app: AppState
    @State private var keys: [ProviderID: String] = [
        .anthropic: KeychainStore.shared.get(.anthropicAPIKey) ?? "",
        .openai: KeychainStore.shared.get(.openAIAPIKey) ?? "",
        .gemini: KeychainStore.shared.get(.geminiAPIKey) ?? ""
    ]
    @State private var models: [ProviderID: [ModelInfo]] = [:]
    @State private var status: [ProviderID: String] = [:]
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Providers (BYO token — keys live in the macOS Keychain)") {
                providerRow(.anthropic, keychainKey: .anthropicAPIKey)
                providerRow(.openai, keychainKey: .openAIAPIKey)
                TextField("OpenAI-compatible base URL", text: $settings.openAIBaseURL)
                    .font(.caption)
                providerRow(.gemini, keychainKey: .geminiAPIKey)
                HStack {
                    Text("Ollama (local, no key)")
                    Spacer()
                    Button("Check") { loadModels(for: .ollama) }
                }
                TextField("Ollama URL", text: $settings.ollamaBaseURL).font(.caption)
                if let s = status[.ollama] { Text(s).font(.caption).foregroundStyle(.secondary) }
            }

            Section("Per-task routing") {
                ForEach(LLMTask.allCases, id: \.self) { task in
                    routeRow(task)
                }
                Text("Route cheap/fast models to detection and summaries, a strong model to planning and code edits. Models are listed live from each provider — nothing is hard-coded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func providerRow(_ provider: ProviderID, keychainKey: KeychainStore.Key) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField("\(provider.displayName) API key",
                            text: Binding(get: { keys[provider] ?? "" },
                                          set: { keys[provider] = $0 }))
                Button("Validate") {
                    KeychainStore.shared.set(keys[provider] ?? "", for: keychainKey)
                    loadModels(for: provider)
                }
            }
            if let s = status[provider] {
                Text(s).font(.caption)
                    .foregroundStyle(s.hasPrefix("✓") ? Color.green : Color.orange)
            }
        }
    }

    private func routeRow(_ task: LLMTask) -> some View {
        HStack {
            Text(task.displayName).frame(width: 210, alignment: .leading)
            Picker("", selection: providerBinding(task)) {
                Text("—").tag(ProviderID?.none)
                ForEach(ProviderID.allCases.filter { $0 != .custom }) { p in
                    Text(p.displayName).tag(ProviderID?.some(p))
                }
            }
            .frame(width: 150)
            Picker("", selection: modelBinding(task)) {
                Text("—").tag("")
                if let provider = settings.routes[task]?.provider {
                    ForEach(models[provider] ?? []) { m in
                        Text(m.displayName).tag(m.id)
                    }
                    // Keep a manually-set model visible even before listing.
                    if let current = settings.routes[task]?.model, !current.isEmpty,
                       !(models[provider] ?? []).contains(where: { $0.id == current }) {
                        Text(current).tag(current)
                    }
                }
            }
        }
    }

    private func providerBinding(_ task: LLMTask) -> Binding<ProviderID?> {
        Binding(get: { settings.routes[task]?.provider },
                set: { newValue in
            if let p = newValue {
                settings.routes[task] = ModelRoute(provider: p,
                                                   model: settings.routes[task]?.provider == p
                                                       ? (settings.routes[task]?.model ?? "") : "")
                loadModels(for: p)
            } else {
                settings.routes.removeValue(forKey: task)
            }
        })
    }

    private func modelBinding(_ task: LLMTask) -> Binding<String> {
        Binding(get: { settings.routes[task]?.model ?? "" },
                set: { newValue in
            if let route = settings.routes[task] {
                settings.routes[task] = ModelRoute(provider: route.provider, model: newValue)
            }
        })
    }

    private func loadModels(for provider: ProviderID) {
        status[provider] = "Checking…"
        Task {
            do {
                let list = try await app.router.listModels(provider: provider)
                models[provider] = list
                status[provider] = "✓ \(list.count) models available"
            } catch {
                status[provider] = Redactor.redact(error.localizedDescription)
            }
        }
    }
}

// MARK: - Integrations

struct IntegrationsSettingsTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore
    @State private var github = KeychainStore.shared.get(.githubToken) ?? ""
    @State private var slack = KeychainStore.shared.get(.slackUserToken) ?? ""
    @State private var linear = KeychainStore.shared.get(.linearAPIKey) ?? ""
    @State private var smtpPassword = KeychainStore.shared.get(.smtpPassword) ?? ""
    @State private var gmailToken = KeychainStore.shared.get(.gmailAccessToken) ?? ""
    @State private var health: [IntegrationID: IntegrationHealth] = [:]
    @State private var manifestSecrets: [String: String] = [:]
    @State private var mcpServers = MCPServerConfig.loadAll()
    @State private var newMCPName = ""
    @State private var newMCPCommand = ""

    var body: some View {
        Form {
            Section("GitHub — fine-grained PAT (repo contents + pull requests)") {
                SecureField("Personal access token", text: $github)
                    .onChange(of: github) { _, v in KeychainStore.shared.set(v, for: .githubToken) }
                TextField("Default repo (owner/name)", text: $settings.githubDefaultRepo)
                healthRow(.github)
            }
            Section("Slack — user token (xoxp-)") {
                SecureField("User OAuth token", text: $slack)
                    .onChange(of: slack) { _, v in KeychainStore.shared.set(v, for: .slackUserToken) }
                TextField("Default channel (#name)", text: $settings.slackDefaultChannel)
                healthRow(.slack)
            }
            Section("Linear — personal API key") {
                SecureField("API key (lin_api_…)", text: $linear)
                    .onChange(of: linear) { _, v in KeychainStore.shared.set(v, for: .linearAPIKey) }
                TextField("Default team key (e.g. ENG)", text: $settings.linearTeamKey)
                healthRow(.linear)
            }
            Section("Email") {
                Picker("Backend", selection: $settings.emailBackend) {
                    ForEach(EmailBackend.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("From address", text: $settings.emailFromAddress)
                if settings.emailBackend == .smtp {
                    TextField("SMTP host (SSL, port 465)", text: $settings.smtpHost)
                    TextField("SMTP username", text: $settings.smtpUsername)
                    SecureField("App password", text: $smtpPassword)
                        .onChange(of: smtpPassword) { _, v in KeychainStore.shared.set(v, for: .smtpPassword) }
                } else {
                    SecureField("Gmail OAuth access token", text: $gmailToken)
                        .onChange(of: gmailToken) { _, v in KeychainStore.shared.set(v, for: .gmailAccessToken) }
                    Text("Paste a token with gmail.send scope (full OAuth flow ships in Phase 5).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                healthRow(.email)
            }
            Section("Manifest integrations (drop a JSON file — no code needed)") {
                ForEach(manifestEntries, id: \.id) { entry in
                    manifestRow(entry)
                }
                HStack {
                    Button("Open manifests folder") {
#if canImport(AppKit)
                        NSWorkspace.shared.open(IntegrationRegistry.manifestsDirectory)
#endif
                    }
                    Text("See docs/INTEGRATIONS.md for the manifest format.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("MCP servers (any Model Context Protocol server's tools)") {
                ForEach(mcpServers) { server in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name)
                            Text(server.command).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        healthRow(server.integrationID)
                        Button {
                            mcpServers.removeAll { $0.id == server.id }
                            MCPServerConfig.saveAll(mcpServers)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Name (e.g. notion)", text: $newMCPName).frame(width: 140)
                    TextField("Command (e.g. npx -y @notionhq/notion-mcp-server)", text: $newMCPCommand)
                    Button("Add") {
                        let id = newMCPName.lowercased()
                            .replacingOccurrences(of: " ", with: "-")
                        guard !id.isEmpty, !newMCPCommand.isEmpty else { return }
                        mcpServers.append(MCPServerConfig(id: id, name: newMCPName,
                                                          command: newMCPCommand))
                        MCPServerConfig.saveAll(mcpServers)
                        newMCPName = ""; newMCPCommand = ""
                    }
                }
            }

            Section {
                Button("Run health checks") { runHealthChecks() }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: Dynamic integrations

    private var manifestEntries: [IntegrationRegistry.KnownIntegration] {
        IntegrationRegistry.shared.known().filter { $0.kind == .manifest }
    }

    private func manifestRow(_ entry: IntegrationRegistry.KnownIntegration) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.id.displayName)
                if let hint = entry.authHint {
                    Text(hint).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            SecureField("API key / token",
                        text: Binding(
                            get: { manifestSecrets[entry.id.rawValue] ?? (entry.configured ? "••••••••" : "") },
                            set: { manifestSecrets[entry.id.rawValue] = $0 }))
                .frame(width: 220)
            Button("Save") {
                if let secret = manifestSecrets[entry.id.rawValue], !secret.isEmpty, !secret.hasPrefix("•") {
                    KeychainStore.shared.setSecret(secret, forIntegration: entry.id.rawValue)
                }
            }
            healthRow(entry.id)
        }
    }

    private func healthRow(_ id: IntegrationID) -> some View {
        Group {
            if let h = health[id] {
                Label(h.message, systemImage: h.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(h.ok ? Color.green : Color.red)
            }
        }
    }

    private func runHealthChecks() {
        Task {
            health = await app.executor.healthChecks()
        }
    }
}

// MARK: - Data (export / erase, spec §4.9)

struct DataSettingsTab: View {
    @EnvironmentObject var app: AppState
    @State private var confirmErase = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Local-first data") {
                Text("Transcripts, decisions, actions, and metrics live in a local SQLite database. They never leave this Mac except as LLM/STT payloads you explicitly configured.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Database", value: AppPaths.database.path)
            }
            Section {
                Button("Export all data (JSON)…") { exportJSON() }
                Button("Delete all data", role: .destructive) { confirmErase = true }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog("Delete all local data? This cannot be undone.",
                            isPresented: $confirmErase) {
            Button("Delete everything", role: .destructive) {
                try? app.store.deleteAllData()
                message = "All local data deleted."
            }
        }
    }

    private func exportJSON() {
#if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "openavatar-export.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try app.store.exportAllJSON().write(to: url)
                message = "Exported to \(url.path)"
            } catch {
                message = "Export failed: \(error.localizedDescription)"
            }
        }
#endif
    }
}
