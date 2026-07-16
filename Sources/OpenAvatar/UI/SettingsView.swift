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
            CalendarSettingsTab()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            TrustMatrixTab()
                .tabItem { Label("Trust", systemImage: "checkmark.shield") }
            MemorySettingsTab()
                .tabItem { Label("Memory", systemImage: "brain.head.profile") }
            TranscriptsSettingsTab()
                .tabItem { Label("Transcripts", systemImage: "text.quote") }
            FollowUpsSettingsTab()
                .tabItem { Label("Follow-ups", systemImage: "bell.badge") }
            MetricsDashboardTab()
                .tabItem { Label("Metrics", systemImage: "chart.bar") }
            DataSettingsTab()
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 720, height: 640)
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
            Section("Updates") {
                LabeledContent("Version", value: UpdateManager.shared.currentVersion)
                Button("Check for updates now") { UpdateManager.shared.checkForUpdates() }
                Text("Updates download automatically in the background; you'll be asked to relaunch when one is ready.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About & legal") {
                Link("Privacy Policy",
                     destination: URL(string: "https://github.com/kocsmy/openavatar/blob/main/PRIVACY.md")!)
                Link("Terms of Service",
                     destination: URL(string: "https://github.com/kocsmy/openavatar/blob/main/TERMS.md")!)
                Text("Everything runs on your Mac. OpenAvatar has no servers and collects no data — see the policy for details.")
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
    @StateObject private var whisperSetup = WhisperSetupService()
    @State private var sttKey = ""
    @State private var sttKeySaved = KeychainStore.shared.get(.cloudSTTAPIKey) != nil
    @State private var showAdvanced = false

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
            Section("Language") {
                Picker("Spoken language", selection: $settings.transcriptionLanguage) {
                    ForEach(TranscriptionLanguage.options, id: \.code) { option in
                        Text(option.label).tag(option.code)
                    }
                }
                Text("Auto-detect handles multilingual calls (e.g. mixing Hungarian and English). Local mode needs the multilingual model — the auto-setup below installs it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speakers") {
                Toggle("Distinguish individual speakers", isOn: $settings.diarizationEnabled)
                Text("On-device per-voice diarization labels each participant on the call (Speaker 1, Speaker 2…) — your own mic is always \"You\". Works fully offline; best with a few clearly-distinct voices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.transcriptionMode == .local {
                Section("Local transcription (whisper.cpp)") {
                    WhisperSetupView(service: whisperSetup)
                    WhisperModelPickerView(service: whisperSetup)
                    DisclosureGroup("Advanced: paths", isExpanded: $showAdvanced) {
                        TextField("whisper-cli path", text: $settings.whisperCLIPath)
                        TextField("Model path (.bin)", text: $settings.whisperModelPath)
                    }
                }
            } else {
                Section("Cloud STT (OpenAI-compatible, BYO key)") {
                    TextField("Base URL", text: $settings.cloudSTTBaseURL)
                    TextField("Model", text: $settings.cloudSTTModel)
                    SecretField(label: "API key", text: $sttKey, saved: $sttKeySaved) {
                        KeychainStore.shared.set(sttKey, for: .cloudSTTAPIKey)
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

/// Shared one-click whisper setup UI (used here and in onboarding).
struct WhisperSetupView: View {
    @ObservedObject var service: WhisperSetupService
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let ready = WhisperSetupService.isReady(settings: settings)
            HStack(spacing: 8) {
                Image(systemName: ready ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(ready ? Color.green : Color.accentColor)
                Text(ready ? "Local transcription is ready."
                           : "One click installs whisper.cpp (via Homebrew) and downloads the multilingual base model (~150 MB).")
                    .font(.callout)
                Spacer()
                Button(ready ? "Re-check" : "Set up automatically") {
                    Task { await service.run(settings: settings) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isBusy)
            }
            switch service.phase {
            case .idle: EmptyView()
            case .checking:
                Label { Text("Checking what's installed…") } icon: { ProgressView().controlSize(.small) }
                    .font(.caption)
            case .installingCLI:
                Label { Text("Installing whisper-cpp via Homebrew (can take a few minutes)…") }
                    icon: { ProgressView().controlSize(.small) }
                    .font(.caption)
            case .downloadingModel(let model):
                Label { Text("Downloading \(model.shortName) model (\(model.sizeLabel))…") }
                    icon: { ProgressView().controlSize(.small) }
                    .font(.caption)
            case .done(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Model-quality picker for local transcription. Switching downloads the
/// chosen model (once) and repoints the model path; already-downloaded models
/// switch instantly.
struct WhisperModelPickerView: View {
    @ObservedObject var service: WhisperSetupService
    @EnvironmentObject var settings: SettingsStore
    @State private var selected: WhisperModel = .base

    private var active: WhisperModel? { WhisperModel.from(path: settings.whisperModelPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Transcription quality", selection: $selected) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                if selected != active {
                    Button("Download & switch") {
                        Task { await service.run(settings: settings, model: selected) }
                    }
                    .controlSize(.small)
                    .disabled(service.isBusy)
                }
            }
            Text("Bigger models transcribe noticeably better, especially with accents, names, and crosstalk — Small is the sweet spot for most Macs; Large v3 Turbo is the best that still keeps up live. Downloads happen once.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { selected = active ?? .base }
        .onChange(of: settings.whisperModelPath) { _, _ in
            selected = active ?? selected
        }
    }
}

// MARK: - Reusable secret field with explicit Save

/// Paste → Save → visible confirmation. Never pre-fills the real secret;
/// shows a "saved" badge when one exists in the Keychain.
struct SecretField: View {
    let label: String
    @Binding var text: String
    @Binding var saved: Bool
    var onSave: () -> Void

    @State private var justSaved = false

    var body: some View {
        HStack(spacing: 8) {
            SecureField(saved ? "\(label) — saved ✓ (paste to replace)" : label, text: $text)
            Button("Save") {
                guard !text.isEmpty else { return }
                onSave()
                saved = true
                text = ""
                justSaved = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    justSaved = false
                }
            }
            .disabled(text.isEmpty)
            if justSaved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else if saved {
                Image(systemName: "key.fill").foregroundStyle(.green)
                    .help("A token is saved in the Keychain")
            }
        }
    }
}

// MARK: - Calendar (Google)

struct CalendarSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var clientSecret = ""
    @State private var clientSecretSaved = KeychainStore.shared.get(.googleClientSecret) != nil
    @State private var connected = GoogleOAuth.shared.isConnected
    @State private var connecting = false
    @State private var status: String?
    @State private var eventPreview: String?

    private let hasBuiltInClient = GoogleOAuth.shared.hasBuiltInClient

    var body: some View {
        Form {
            Section("Google Calendar") {
                Toggle("Identify who's on the call from my calendar", isOn: $settings.calendarEnabled)
                Text("When you start listening, OpenAvatar looks up the current event and offers each attendee's name to label the voices it hears. On a 1:1 it pre-fills the other person automatically. Read-only — it never changes your calendar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Connection") {
                if connected {
                    HStack {
                        Label("Connected to Google Calendar", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Disconnect") {
                            Task {
                                await GoogleOAuth.shared.disconnect()
                                connected = false
                                status = "Disconnected."
                                eventPreview = nil
                            }
                        }
                    }
                    Button {
                        testFetch()
                    } label: {
                        Label("Test — read my current event", systemImage: "arrow.clockwise")
                    }
                    .disabled(connecting)
                    if let eventPreview {
                        Text(eventPreview).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        connect()
                    } label: {
                        if connecting { ProgressView().controlSize(.small) }
                        else { Label("Connect Google Calendar", systemImage: "person.badge.key") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(connecting || !isConfigured)
                    if hasBuiltInClient {
                        Text("One click — sign in with Google and approve read-only calendar access. Your tokens stay in your Keychain on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !isConfigured {
                        Text("Add an OAuth client under Advanced first.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if hasBuiltInClient {
                Section {
                    DisclosureGroup("Advanced — use your own Google app") {
                        oauthCredentialFields
                        setupInstructions
                    }
                }
            } else {
                Section("OAuth credentials (from your Google Cloud project)") {
                    oauthCredentialFields
                }
                Section("Setup") { setupInstructions }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder private var oauthCredentialFields: some View {
        TextField("Client ID", text: $settings.googleClientID)
            .textFieldStyle(.roundedBorder)
        SecretField(label: "Client secret", text: $clientSecret, saved: $clientSecretSaved) {
            KeychainStore.shared.set(clientSecret, for: .googleClientSecret)
        }
        TextField("My email (auto-filled on connect)", text: $settings.calendarSelfEmail)
            .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder private var setupInstructions: some View {
        Text("""
        1. In Google Cloud Console, create an OAuth client of type **Desktop app**.
        2. Enable the **Google Calendar API** for the project.
        3. Paste the client ID and client secret above.
        4. Click Connect and approve read-only calendar access.
        Tokens are stored in your Keychain; OpenAvatar only ever reads events, never writes.
        """)
        .font(.caption).foregroundStyle(.secondary)
        Button("Open Google Cloud Console") {
#if canImport(AppKit)
            if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
                NSWorkspace.shared.open(url)
            }
#endif
        }
    }

    private var isConfigured: Bool {
        if hasBuiltInClient { return true }
        return !settings.googleClientID.trimmingCharacters(in: .whitespaces).isEmpty && clientSecretSaved
    }

    private func connect() {
        connecting = true
        status = "Opening your browser to sign in…"
        Task {
            defer { connecting = false }
            do {
                try await GoogleOAuth.shared.connect()
                connected = true
                status = "Connected. Calendar look-up is ready."
            } catch {
                status = Redactor.redact(error.localizedDescription)
            }
        }
    }

    private func testFetch() {
        connecting = true
        eventPreview = "Reading…"
        Task {
            defer { connecting = false }
            do {
                let client = GoogleCalendarClient(
                    tokenProvider: { try await GoogleOAuth.shared.accessToken() })
                if let event = try await client.currentEvent() {
                    let names = event.others(excludingSelfEmail: settings.calendarSelfEmail)
                        .map(\.name).joined(separator: ", ")
                    eventPreview = "“\(event.title)” — \(names.isEmpty ? "no other attendees" : names)"
                } else {
                    eventPreview = "No event scheduled around now."
                }
            } catch {
                eventPreview = Redactor.redact(error.localizedDescription)
            }
        }
    }
}

// MARK: - Models (LLM providers + per-task routing)

struct ModelsSettingsTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore
    @State private var keys: [ProviderID: String] = [:]
    @State private var keySaved: [ProviderID: Bool] = [
        .anthropic: KeychainStore.shared.get(.anthropicAPIKey) != nil,
        .openai: KeychainStore.shared.get(.openAIAPIKey) != nil,
        .gemini: KeychainStore.shared.get(.geminiAPIKey) != nil
    ]
    @State private var models: [ProviderID: [ModelInfo]] = [:]
    @State private var status: [ProviderID: String] = [:]
    @State private var routeTestResults: [LLMTask: String] = [:]
    @State private var testingRoutes = false

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
                if let s = status[.ollama] { statusText(s) }
            }

            Section("Per-task routing") {
                ForEach(LLMTask.allCases, id: \.self) { task in
                    routeRow(task)
                }
                Text("Route cheap/fast models to detection and summaries, a strong model to planning and code edits. Models are listed live from each provider — nothing is hard-coded.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Verify") {
                HStack {
                    Button("Send test message through each route") { testRoutes() }
                        .disabled(testingRoutes)
                    if testingRoutes { ProgressView().controlSize(.small) }
                }
                ForEach(LLMTask.allCases, id: \.self) { task in
                    if let result = routeTestResults[task] {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.displayName).font(.caption.weight(.semibold))
                            Text(result)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(result.hasPrefix("✓") ? Color.green : Color.orange)
                                .textSelection(.enabled)
                        }
                    }
                }
                Text("If a call fails mid-call, the full API error appears here and in the menu-bar popover — no more truncated messages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func statusText(_ s: String) -> some View {
        Text(s).font(.caption)
            .foregroundStyle(s.hasPrefix("✓") ? Color.green : Color.orange)
            .textSelection(.enabled)
    }

    private func providerRow(_ provider: ProviderID, keychainKey: KeychainStore.Key) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SecretField(label: "\(provider.displayName) API key",
                        text: Binding(get: { keys[provider] ?? "" },
                                      set: { keys[provider] = $0 }),
                        saved: Binding(get: { keySaved[provider] ?? false },
                                       set: { keySaved[provider] = $0 })) {
                KeychainStore.shared.set(keys[provider] ?? "", for: keychainKey)
                loadModels(for: provider)
            }
            if let s = status[provider] { statusText(s) }
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

    /// End-to-end verification: a real (tiny) completion through each
    /// configured route, surfacing the FULL error on failure.
    private func testRoutes() {
        testingRoutes = true
        routeTestResults = [:]
        Task {
            defer { testingRoutes = false }
            for task in LLMTask.allCases {
                guard settings.routes[task] != nil else {
                    routeTestResults[task] = "no model configured"
                    continue
                }
                do {
                    let response = try await app.router.complete(task: task, LLMRequest(
                        model: "",
                        messages: [ChatMessage(role: .user, content: "Reply with exactly: OK")],
                        maxTokens: 16))
                    routeTestResults[task] = "✓ \(response.model): \(response.text.prefix(40))"
                } catch {
                    routeTestResults[task] = Redactor.redact(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Integrations

struct IntegrationsSettingsTab: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore

    @State private var github = ""
    @State private var githubSaved = KeychainStore.shared.get(.githubToken) != nil
    @State private var slack = ""
    @State private var slackSaved = KeychainStore.shared.get(.slackUserToken) != nil
    @State private var linear = ""
    @State private var linearSaved = KeychainStore.shared.get(.linearAPIKey) != nil
    @State private var smtpPassword = ""
    @State private var smtpSaved = KeychainStore.shared.get(.smtpPassword) != nil
    @State private var gmailToken = ""
    @State private var gmailSaved = KeychainStore.shared.get(.gmailAccessToken) != nil

    @State private var health: [IntegrationID: IntegrationHealth] = [:]
    @State private var checking = false
    @State private var manifestSecrets: [String: String] = [:]
    @State private var manifestSaved: [String: Bool] = [:]
    @State private var mcpServers = MCPServerConfig.loadAll()
    @State private var newMCPName = ""
    @State private var newMCPCommand = ""

    var body: some View {
        Form {
            Section("GitHub — fine-grained PAT (repo contents + pull requests)") {
                SecretField(label: "Personal access token", text: $github, saved: $githubSaved) {
                    KeychainStore.shared.set(github, for: .githubToken)
                    check(.github)
                }
                TextField("Default repo (owner/name)", text: $settings.githubDefaultRepo)
                healthRow(.github)
            }
            Section("Slack — user token (xoxp-)") {
                SecretField(label: "User OAuth token", text: $slack, saved: $slackSaved) {
                    KeychainStore.shared.set(slack, for: .slackUserToken)
                    check(.slack)
                }
                TextField("Default channel (#name)", text: $settings.slackDefaultChannel)
                healthRow(.slack)
            }
            Section("Linear — personal API key") {
                SecretField(label: "API key (lin_api_…)", text: $linear, saved: $linearSaved) {
                    KeychainStore.shared.set(linear, for: .linearAPIKey)
                    check(.linear)
                }
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
                    SecretField(label: "App password", text: $smtpPassword, saved: $smtpSaved) {
                        KeychainStore.shared.set(smtpPassword, for: .smtpPassword)
                        check(.email)
                    }
                } else {
                    SecretField(label: "Gmail OAuth access token", text: $gmailToken, saved: $gmailSaved) {
                        KeychainStore.shared.set(gmailToken, for: .gmailAccessToken)
                        check(.email)
                    }
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
                HStack {
                    Button("Test all connections") { checkAll() }
                        .disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func healthRow(_ id: IntegrationID) -> some View {
        Group {
            if let h = health[id] {
                Label(h.message, systemImage: h.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(h.ok ? Color.green : Color.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var manifestEntries: [IntegrationRegistry.KnownIntegration] {
        IntegrationRegistry.shared.known().filter { $0.kind == .manifest }
    }

    private func manifestRow(_ entry: IntegrationRegistry.KnownIntegration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.id.displayName).font(.callout.weight(.medium))
                if let hint = entry.authHint {
                    Text(hint).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            SecretField(label: "API key / token",
                        text: Binding(get: { manifestSecrets[entry.id.rawValue] ?? "" },
                                      set: { manifestSecrets[entry.id.rawValue] = $0 }),
                        saved: Binding(get: { manifestSaved[entry.id.rawValue] ?? entry.configured },
                                       set: { manifestSaved[entry.id.rawValue] = $0 })) {
                if let secret = manifestSecrets[entry.id.rawValue], !secret.isEmpty {
                    KeychainStore.shared.setSecret(secret, forIntegration: entry.id.rawValue)
                    check(entry.id)
                }
            }
            healthRow(entry.id)
        }
    }

    private func check(_ id: IntegrationID) {
        Task {
            if let integration = await app.executor.integrations()[id] {
                health[id] = await integration.healthCheck()
            } else {
                health[id] = IntegrationHealth(ok: false, message: "Not configured yet")
            }
        }
    }

    private func checkAll() {
        checking = true
        Task {
            health = await app.executor.healthChecks()
            checking = false
        }
    }
}

// MARK: - Data (export / erase / error log)

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
            if !app.errorLog.isEmpty {
                Section("Error log (this session)") {
                    ForEach(app.errorLog) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.at.formatted(date: .omitted, time: .standard))
                                .font(.caption2).foregroundStyle(.tertiary)
                            Text(entry.message)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    Button("Clear error log") { app.clearErrors() }
                }
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
