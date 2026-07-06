import Foundation

/// Routes each task class (detection / planning / summary) to the user's
/// configured provider+model; applies uniform retry with exponential backoff
/// on 429/5xx; persists token usage per call (spec §4.3).
///
/// Providers are constructed fresh per call from current settings/keys, so
/// switching provider in Settings mid-session requires no restart (Phase 2
/// acceptance criterion).
actor LLMRouter {
    private let keychain: KeychainStore
    private let store: ContextStore?

    var maxRetries = 3

    init(keychain: KeychainStore = .shared, store: ContextStore?) {
        self.keychain = keychain
        self.store = store
    }

    // MARK: Provider construction

    func provider(for id: ProviderID) throws -> LLMProvider {
        let settings = readSettings()
        switch id {
        case .anthropic:
            guard let key = keychain.get(.anthropicAPIKey) else {
                throw AppError.notConfigured("Anthropic API key")
            }
            return AnthropicProvider(apiKey: key)
        case .openai, .custom:
            guard let key = keychain.get(.openAIAPIKey) else {
                throw AppError.notConfigured("OpenAI API key")
            }
            let base = URL(string: settings.openAIBase) ?? URL(string: "https://api.openai.com/v1")!
            return OpenAIProvider(apiKey: key, baseURL: base)
        case .gemini:
            guard let key = keychain.get(.geminiAPIKey) else {
                throw AppError.notConfigured("Gemini API key")
            }
            return GeminiProvider(apiKey: key)
        case .ollama:
            let base = URL(string: settings.ollamaBase) ?? URL(string: "http://localhost:11434")!
            return OllamaProvider(baseURL: base)
        }
    }

    private struct RawSettings {
        var openAIBase: String
        var ollamaBase: String
        var routes: [String: [String: String]]
    }

    /// Reads directly from UserDefaults so the actor never touches the
    /// main-actor-bound SettingsStore.
    private func readSettings() -> RawSettings {
        let d = UserDefaults.standard
        return RawSettings(
            openAIBase: d.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1",
            ollamaBase: d.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434",
            routes: (d.dictionary(forKey: "modelRoutes") as? [String: [String: String]]) ?? [:])
    }

    func route(for task: LLMTask) throws -> ModelRoute {
        let routes = readSettings().routes
        if let raw = routes[task.rawValue],
           let provider = ProviderID(rawValue: raw["provider"] ?? ""),
           let model = raw["model"], !model.isEmpty {
            return ModelRoute(provider: provider, model: model)
        }
        // Fall back to any configured route (e.g. only "planning" was set up).
        for fallbackTask in LLMTask.allCases {
            if let raw = routes[fallbackTask.rawValue],
               let provider = ProviderID(rawValue: raw["provider"] ?? ""),
               let model = raw["model"], !model.isEmpty {
                return ModelRoute(provider: provider, model: model)
            }
        }
        throw AppError.notConfigured("No model configured for \(task.displayName) — set one in Settings → Models")
    }

    // MARK: Completion with retry + usage accounting

    func complete(task: LLMTask, _ request: LLMRequest) async throws -> LLMResponse {
        var request = request
        let route = try route(for: task)
        if request.model.isEmpty { request.model = route.model }
        let provider = try self.provider(for: route.provider)

        var attempt = 0
        while true {
            do {
                let response = try await provider.complete(request)
                try? store?.recordUsage(provider: route.provider, model: request.model,
                                        task: task, usage: response.usage)
                return response
            } catch let error as AppError where error.isRetryable && attempt < maxRetries {
                attempt += 1
                let delay = UInt64(pow(2.0, Double(attempt)) * 500_000_000) // 1s, 2s, 4s
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    func listModels(provider id: ProviderID) async throws -> [ModelInfo] {
        try await provider(for: id).listModels()
    }
}
