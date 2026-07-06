import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Onboarding wizard (spec §4.10), Wispr-Flow-style: one concept per screen,
/// permission priming before each system prompt, live validation of keys and
/// integrations, and a "try it" moment at the end. Every step is skippable.
struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore
    @State private var step = 0

    private let stepCount = 9

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 48)
                .padding(.top, 36)

            footer
                .padding(24)
        }
        .frame(width: 720, height: 560)
        .background(.background)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: WelcomeStep()
        case 1: HowItWorksStep()
        case 2: PermissionsStep()
        case 3: TranscriptionStep()
        case 4: LLMStep()
        case 5: IntegrationsStep()
        case 6: IdentityStep()
        case 7: TrustStep()
        case 8: BaselineAndFinishStep()
        default: WelcomeStep()
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { step = max(0, step - 1) }
                .disabled(step == 0)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step < stepCount - 1 {
                Button("Skip") { step += 1 }
                Button("Continue") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Start using \(settings.assistantName)") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finish() {
        settings.onboardingComplete = true
#if canImport(AppKit)
        WindowManager.shared.close(id: "onboarding")
#endif
    }
}

// MARK: - Shared pieces

private struct StepHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

// MARK: - Step 0: Welcome

private struct WelcomeStep: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(icon: "waveform.circle.fill",
                       title: "Meet \(settings.assistantName)",
                       subtitle: "Your calls end with things done — not with a to-do list.")
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(icon: "ear.badge.waveform",
                           title: "Listens locally to your calls",
                           detail: "Zoom, Meet, Slack huddles, Teams — audio is captured on this Mac. It never joins the call and nothing records unless you switch it on.")
                FeatureRow(icon: "sparkles",
                           title: "Detects decisions as they happen",
                           detail: "“Let's ship the header fix”, “File a ticket for that”, “Tell #design it's ready” — each becomes an actionable item with the exact quote.")
                FeatureRow(icon: "bolt.badge.checkmark",
                           title: "Executes them for you",
                           detail: "Opens PRs, creates Linear tickets, posts to Slack, sends email — under your accounts, always marked with 🤖 so everyone knows what was automated.")
            }
            .frame(maxWidth: 560)
        }
    }
}

// MARK: - Step 1: How it works (modes + trust)

private struct HowItWorksStep: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(icon: "slider.horizontal.3",
                       title: "You stay in control",
                       subtitle: "Two modes, one trust ladder. Nothing destructive happens without you.")
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(icon: "tray.full",
                           title: "Passive mode (default)",
                           detail: "Decisions pile up quietly during the call. When it ends, you get a review sheet: Approve, Edit, or Dismiss each one. Approved items are executed by the app immediately.")
                FeatureRow(icon: "bolt",
                           title: "Active mode",
                           detail: "Say “\(settings.assistantName), open a ticket for that” mid-call and it happens right away — for action types you've marked Autonomous.")
                FeatureRow(icon: "checkmark.shield",
                           title: "The trust ladder",
                           detail: "Every action type starts as Ask-first. Risky actions (merging PRs, sending email) can only go Autonomous after 10 approvals without a single revert or edit. One-click Undo everywhere it's possible.")
            }
            .frame(maxWidth: 560)
        }
    }
}

// MARK: - Step 2: Permissions (primed before the system prompt)

private struct PermissionsStep: View {
    @State private var micGranted: Bool?

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(icon: "mic.badge.plus",
                       title: "Two permissions, both local",
                       subtitle: "Audio is processed on this Mac. The menu-bar icon always shows when recording is on, and ⌘⇧L stops it instantly.")
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    FeatureRow(icon: "mic",
                               title: "Microphone",
                               detail: "Your side of the conversation.")
                    Button(buttonLabel) { requestMic() }
                        .buttonStyle(.borderedProminent)
                        .disabled(micGranted == true)
                }
                FeatureRow(icon: "speaker.wave.3",
                           title: "System audio",
                           detail: "The other participants. macOS will ask the first time you start listening during a call — approve “Audio Recording” when prompted.")
            }
            .frame(maxWidth: 560)
        }
    }

    private var buttonLabel: String {
        switch micGranted {
        case .some(true): return "Granted ✓"
        case .some(false): return "Open System Settings"
        case nil: return "Allow microphone"
        }
    }

    private func requestMic() {
#if canImport(AVFoundation)
        if micGranted == false {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { micGranted = granted }
        }
#endif
    }
}

// MARK: - Step 3: Transcription

private struct TranscriptionStep: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var sttKey = KeychainStore.shared.get(.cloudSTTAPIKey) ?? ""

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(icon: "waveform",
                       title: "How should calls be transcribed?",
                       subtitle: "Local keeps audio on this Mac. Cloud is more accurate on noisy calls but sends audio to your provider.")
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $settings.transcriptionMode) {
                    ForEach(TranscriptionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if settings.transcriptionMode == .local {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Needs whisper.cpp: `brew install whisper-cpp`, plus a model file. Paths can be adjusted later in Settings → Transcription.")
                                .font(.callout)
                            TextField("whisper-cli path", text: $settings.whisperCLIPath)
                            TextField("Model path (.bin)", text: $settings.whisperModelPath)
                        }.padding(6)
                    }
                } else {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Call audio will be sent to the provider below.",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            TextField("Base URL", text: $settings.cloudSTTBaseURL)
                            SecureField("API key", text: $sttKey)
                                .onChange(of: sttKey) { _, v in
                                    KeychainStore.shared.set(v, for: .cloudSTTAPIKey)
                                }
                        }.padding(6)
                    }
                }
            }
            .frame(maxWidth: 520)
        }
    }
}

// MARK: - Step 4: LLM provider + key (validated live)

private struct LLMStep: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore
    @State private var provider: ProviderID = .anthropic
    @State private var key = ""
    @State private var status: String?
    @State private var models: [ModelInfo] = []
    @State private var selectedModel = ""

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(icon: "brain",
                       title: "Connect a model",
                       subtitle: "Bring your own key — Anthropic, OpenAI, Gemini, or a local Ollama. You can route different tasks to different models later.")
            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: $provider) {
                    ForEach(ProviderID.allCases.filter { $0 != .custom }) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                if provider != .ollama {
                    SecureField("API key", text: $key)
                }
                HStack {
                    Button("Validate & list models") { validate() }
                        .buttonStyle(.borderedProminent)
                    if let status {
                        Text(status).font(.callout)
                            .foregroundStyle(status.hasPrefix("✓") ? Color.green : Color.orange)
                    }
                }
                if !models.isEmpty {
                    Picker("Model for everything (refine later)", selection: $selectedModel) {
                        ForEach(models) { Text($0.displayName).tag($0.id) }
                    }
                    .onChange(of: selectedModel) { _, model in
                        for task in LLMTask.allCases {
                            settings.routes[task] = ModelRoute(provider: provider, model: model)
                        }
                    }
                }
            }
            .frame(maxWidth: 520)
        }
    }

    private func validate() {
        let keychainKey: KeychainStore.Key? = switch provider {
        case .anthropic: .anthropicAPIKey
        case .openai, .custom: .openAIAPIKey
        case .gemini: .geminiAPIKey
        case .ollama: nil
        }
        if let keychainKey, !key.isEmpty {
            KeychainStore.shared.set(key, for: keychainKey)
        }
        status = "Checking…"
        Task {
            do {
                let list = try await app.router.listModels(provider: provider)
                models = list
                if let first = list.first {
                    selectedModel = first.id
                    for task in LLMTask.allCases {
                        settings.routes[task] = ModelRoute(provider: provider, model: first.id)
                    }
                }
                status = "✓ Key works — \(list.count) models"
            } catch {
                status = Redactor.redact(error.localizedDescription)
            }
        }
    }
}

// MARK: - Step 5: Integrations (validated with healthCheck)

private struct IntegrationsStep: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore
    @State private var github = ""
    @State private var slack = ""
    @State private var linear = ""
    @State private var health: [IntegrationID: IntegrationHealth] = [:]

    var body: some View {
        VStack(spacing: 20) {
            StepHeader(icon: "puzzlepiece.extension",
                       title: "Connect your tools",
                       subtitle: "Connect at least one now — the rest any time in Settings. Email setup lives in Settings → Integrations.")
            VStack(alignment: .leading, spacing: 10) {
                tokenRow("GitHub fine-grained PAT", text: $github, id: .github) {
                    KeychainStore.shared.set(github, for: .githubToken)
                }
                TextField("Default repo (owner/name)", text: $settings.githubDefaultRepo)
                    .font(.callout)
                tokenRow("Slack user token (xoxp-…)", text: $slack, id: .slack) {
                    KeychainStore.shared.set(slack, for: .slackUserToken)
                }
                tokenRow("Linear API key (lin_api_…)", text: $linear, id: .linear) {
                    KeychainStore.shared.set(linear, for: .linearAPIKey)
                }
            }
            .frame(maxWidth: 540)
        }
    }

    private func tokenRow(_ label: String, text: Binding<String>, id: IntegrationID,
                          save: @escaping () -> Void) -> some View {
        HStack {
            SecureField(label, text: text)
            Button("Connect") {
                save()
                Task { health = await app.executor.healthChecks() }
            }
            if let h = health[id] {
                Image(systemName: h.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(h.ok ? Color.green : Color.red)
                    .help(h.message)
            }
        }
    }
}

// MARK: - Step 6: Assistant name / wake phrase

private struct IdentityStep: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(icon: "person.wave.2",
                       title: "Name your assistant",
                       subtitle: "The name is also the wake phrase in Active mode.")
            VStack(alignment: .leading, spacing: 12) {
                TextField("Assistant name", text: $settings.assistantName)
                    .font(.title3)
                Text("On a call you'll say: “\(settings.assistantName), create a ticket for the login bug.”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Your name (shown in email attribution)", text: $settings.userDisplayName)
            }
            .frame(maxWidth: 440)
        }
    }
}

// MARK: - Step 7: Trust defaults

private struct TrustStep: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(icon: "checkmark.shield",
                       title: "Safe defaults",
                       subtitle: "Everything asks first, except two low-risk actions in Active mode. Adjust the full matrix any time in Settings → Trust.")
            VStack(alignment: .leading, spacing: 12) {
                Label("PR comments and Linear tickets: autonomous when you address \(settings.assistantName) directly", systemImage: "bolt")
                Label("Everything else: preview → your approval → executed", systemImage: "hand.raised")
                Label("Merges and emails: locked to Ask-first until 10 clean approvals", systemImage: "lock")
                Label("Requests spoken by other participants: never destructive without you", systemImage: "person.2.slash")
            }
            .font(.callout)
            .frame(maxWidth: 540)
            Button("Reset to these defaults") { settings.trustMatrix = .defaults }
                .controlSize(.small)
        }
    }
}

// MARK: - Step 8: Baseline + finish (PRD §7)

private struct BaselineAndFinishStep: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: SettingsStore
    @State private var minutes: Double = 30

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(icon: "chart.line.uptrend.xyaxis",
                       title: "One last thing",
                       subtitle: "So the metrics dashboard can show what you're saving:")
            VStack(spacing: 12) {
                Text("Roughly how many minutes per day do you spend routing post-call tasks — filing tickets, pinging people, writing follow-up emails?")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                HStack {
                    Slider(value: $minutes, in: 0...180, step: 5)
                    Text("\(Int(minutes)) min").monospacedDigit().frame(width: 70)
                }
                .frame(maxWidth: 440)
                .onChange(of: minutes) { _, v in
                    settings.adminMinutesBaseline = Int(v)
                    try? MetricsRecorder(store: app.store).setBaseline(minutes: Int(v))
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Try it now").font(.headline)
                    Text("Click the \(Image(systemName: "waveform.circle")) icon in your menu bar, press Listen, and say: “\(settings.assistantName), create a ticket to test my setup.” Then approve it from the popover.")
                        .font(.callout)
                }
                .padding(8)
            }
            .frame(maxWidth: 540)
        }
    }
}
