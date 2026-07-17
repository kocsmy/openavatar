import Foundation
import Combine

enum TranscriptionMode: String, Codable, CaseIterable {
    case local  // whisper.cpp — private, offline (default)
    case cloud  // BYO-key OpenAI-compatible STT

    var displayName: String {
        self == .local ? "Local (private, offline)" : "Cloud (BYO key)"
    }
}

enum EmailBackend: String, Codable, CaseIterable {
    case smtp   // generic SMTP with app password
    case gmail  // Gmail API via OAuth

    var displayName: String { self == .smtp ? "SMTP (app password)" : "Gmail API (OAuth)" }
}

struct ModelRoute: Codable, Equatable {
    var provider: ProviderID
    var model: String
}

/// Language options for the transcription picker. "auto" detects per chunk;
/// the rest are common whisper language codes. Not exhaustive — whisper
/// supports ~99 languages; a manual code in Advanced also works.
enum TranscriptionLanguage {
    static let options: [(code: String, label: String)] = [
        ("auto", "Auto-detect (multilingual)"),
        ("en", "English"),
        ("hu", "Hungarian"),
        ("de", "German"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("ru", "Russian"),
        ("uk", "Ukrainian"),
        ("tr", "Turkish"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese")
    ]
}

/// Non-secret settings, UserDefaults-backed. Secrets are in KeychainStore only.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    // MARK: General
    @Published var assistantName: String { didSet { defaults.set(assistantName, forKey: "assistantName") } }
    @Published var mode: AssistantMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: "onboardingComplete") } }

    // MARK: Transcription
    @Published var transcriptionMode: TranscriptionMode { didSet { defaults.set(transcriptionMode.rawValue, forKey: "transcriptionMode") } }
    @Published var whisperCLIPath: String { didSet { defaults.set(whisperCLIPath, forKey: "whisperCLIPath") } }
    @Published var whisperModelPath: String { didSet { defaults.set(whisperModelPath, forKey: "whisperModelPath") } }
    @Published var cloudSTTBaseURL: String { didSet { defaults.set(cloudSTTBaseURL, forKey: "cloudSTTBaseURL") } }
    @Published var cloudSTTModel: String { didSet { defaults.set(cloudSTTModel, forKey: "cloudSTTModel") } }
    /// "auto" detects language per chunk; or a whisper code like "hu", "en".
    @Published var transcriptionLanguage: String { didSet { defaults.set(transcriptionLanguage, forKey: "transcriptionLanguage") } }
    /// Per-voice diarization on the system-audio channel (Speaker 1/2/3…).
    @Published var diarizationEnabled: Bool { didSet { defaults.set(diarizationEnabled, forKey: "diarizationEnabled") } }
    /// Comma-separated names/jargon to bias transcription toward spelling
    /// correctly (product names like "PostHog, Termly, Linear"). Speaker and
    /// calendar-attendee names are added automatically at call time.
    @Published var customVocabulary: String { didSet { defaults.set(customVocabulary, forKey: "customVocabulary") } }

    // MARK: LLM
    @Published var openAIBaseURL: String { didSet { defaults.set(openAIBaseURL, forKey: "openAIBaseURL") } }
    @Published var ollamaBaseURL: String { didSet { defaults.set(ollamaBaseURL, forKey: "ollamaBaseURL") } }
    @Published var routes: [LLMTask: ModelRoute] { didSet { persistRoutes() } }

    // MARK: Detection
    @Published var confidenceThreshold: Double { didSet { defaults.set(confidenceThreshold, forKey: "confidenceThreshold") } }
    /// Capture time-referenced follow-ups from calls and offer reminders for them.
    @Published var followUpsEnabled: Bool { didSet { defaults.set(followUpsEnabled, forKey: "followUpsEnabled") } }

    // MARK: Trust — changes only via explicit user action (spec §5.4)
    @Published var trustMatrix: TrustMatrix { didSet { persistTrustMatrix() } }

    // MARK: Email
    @Published var emailBackend: EmailBackend { didSet { defaults.set(emailBackend.rawValue, forKey: "emailBackend") } }
    @Published var smtpHost: String { didSet { defaults.set(smtpHost, forKey: "smtpHost") } }
    @Published var smtpPort: Int { didSet { defaults.set(smtpPort, forKey: "smtpPort") } }
    @Published var smtpUsername: String { didSet { defaults.set(smtpUsername, forKey: "smtpUsername") } }
    @Published var emailFromAddress: String { didSet { defaults.set(emailFromAddress, forKey: "emailFromAddress") } }
    @Published var userDisplayName: String { didSet { defaults.set(userDisplayName, forKey: "userDisplayName") } }

    // MARK: Calendar (Google) — non-secret parts
    /// OAuth client ID from the user's Google Cloud project (Desktop app type).
    @Published var googleClientID: String { didSet { defaults.set(googleClientID, forKey: "googleClientID") } }
    /// Read the calendar on call start to identify participants / pre-fill names.
    @Published var calendarEnabled: Bool { didSet { defaults.set(calendarEnabled, forKey: "calendarEnabled") } }
    /// The user's own email, used to exclude "self" from participant name suggestions.
    @Published var calendarSelfEmail: String { didSet { defaults.set(calendarSelfEmail, forKey: "calendarSelfEmail") } }

    // MARK: Integrations (non-secret parts)
    @Published var githubDefaultRepo: String { didSet { defaults.set(githubDefaultRepo, forKey: "githubDefaultRepo") } }
    @Published var linearTeamKey: String { didSet { defaults.set(linearTeamKey, forKey: "linearTeamKey") } }
    @Published var slackDefaultChannel: String { didSet { defaults.set(slackDefaultChannel, forKey: "slackDefaultChannel") } }
    @Published var repoTestCommands: [String: String] { didSet { persistRepoTestCommands() } }

    // MARK: Metrics baseline (PRD §7)
    @Published var adminMinutesBaseline: Int { didSet { defaults.set(adminMinutesBaseline, forKey: "adminMinutesBaseline") } }

    private init() {
        assistantName = defaults.string(forKey: "assistantName") ?? "Avatar"
        mode = AssistantMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .passive
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")

        transcriptionMode = TranscriptionMode(rawValue: defaults.string(forKey: "transcriptionMode") ?? "") ?? .local
        whisperCLIPath = defaults.string(forKey: "whisperCLIPath") ?? "/opt/homebrew/bin/whisper-cli"
        whisperModelPath = defaults.string(forKey: "whisperModelPath")
            ?? AppPaths.models.appendingPathComponent("ggml-base.bin").path
        cloudSTTBaseURL = defaults.string(forKey: "cloudSTTBaseURL") ?? "https://api.openai.com/v1"
        cloudSTTModel = defaults.string(forKey: "cloudSTTModel") ?? "whisper-1"
        transcriptionLanguage = defaults.string(forKey: "transcriptionLanguage") ?? "auto"
        diarizationEnabled = (defaults.object(forKey: "diarizationEnabled") as? Bool) ?? true
        customVocabulary = defaults.string(forKey: "customVocabulary") ?? ""

        openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
        ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        routes = Self.loadRoutes(from: defaults)

        let threshold = defaults.object(forKey: "confidenceThreshold") as? Double
        confidenceThreshold = threshold ?? 0.6
        followUpsEnabled = (defaults.object(forKey: "followUpsEnabled") as? Bool) ?? true

        trustMatrix = Self.loadTrustMatrix(from: defaults)

        emailBackend = EmailBackend(rawValue: defaults.string(forKey: "emailBackend") ?? "") ?? .smtp
        smtpHost = defaults.string(forKey: "smtpHost") ?? ""
        smtpPort = defaults.object(forKey: "smtpPort") as? Int ?? 465
        smtpUsername = defaults.string(forKey: "smtpUsername") ?? ""
        emailFromAddress = defaults.string(forKey: "emailFromAddress") ?? ""
        userDisplayName = defaults.string(forKey: "userDisplayName") ?? NSFullUserName()

        googleClientID = defaults.string(forKey: "googleClientID") ?? ""
        calendarEnabled = (defaults.object(forKey: "calendarEnabled") as? Bool) ?? false
        calendarSelfEmail = defaults.string(forKey: "calendarSelfEmail") ?? ""

        githubDefaultRepo = defaults.string(forKey: "githubDefaultRepo") ?? ""
        linearTeamKey = defaults.string(forKey: "linearTeamKey") ?? ""
        slackDefaultChannel = defaults.string(forKey: "slackDefaultChannel") ?? ""
        repoTestCommands = (defaults.dictionary(forKey: "repoTestCommands") as? [String: String]) ?? [:]

        adminMinutesBaseline = defaults.integer(forKey: "adminMinutesBaseline")
    }

    // MARK: Persistence helpers

    private func persistRoutes() {
        let raw = routes.reduce(into: [String: [String: String]]()) { acc, entry in
            acc[entry.key.rawValue] = ["provider": entry.value.provider.rawValue, "model": entry.value.model]
        }
        defaults.set(raw, forKey: "modelRoutes")
    }

    private static func loadRoutes(from defaults: UserDefaults) -> [LLMTask: ModelRoute] {
        guard let raw = defaults.dictionary(forKey: "modelRoutes") as? [String: [String: String]] else { return [:] }
        var out: [LLMTask: ModelRoute] = [:]
        for (k, v) in raw {
            if let task = LLMTask(rawValue: k),
               let provider = ProviderID(rawValue: v["provider"] ?? ""),
               let model = v["model"] {
                out[task] = ModelRoute(provider: provider, model: model)
            }
        }
        return out
    }

    private func persistTrustMatrix() {
        if let data = try? JSONEncoder().encode(trustMatrix) {
            defaults.set(data, forKey: "trustMatrix")
        }
    }

    private static func loadTrustMatrix(from defaults: UserDefaults) -> TrustMatrix {
        if let data = defaults.data(forKey: "trustMatrix"),
           let matrix = try? JSONDecoder().decode(TrustMatrix.self, from: data) {
            return matrix
        }
        return .defaults
    }

    private func persistRepoTestCommands() {
        defaults.set(repoTestCommands, forKey: "repoTestCommands")
    }
}

/// App-managed directories (spec §5.5: never touch user-cloned repos in place).
enum AppPaths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenAvatar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var repos: URL {
        let url = appSupport.appendingPathComponent("repos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var models: URL {
        let url = appSupport.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var database: URL {
        appSupport.appendingPathComponent("openavatar.sqlite")
    }

    static var scratch: URL {
        let url = appSupport.appendingPathComponent("scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
