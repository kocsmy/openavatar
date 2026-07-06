import Foundation
#if canImport(Security)
import Security
#endif

/// All secrets live here and only here (spec §4.10 / §5).
/// Never logged, never written to SQLite, redacted from debug output.
struct KeychainStore {
    static let shared = KeychainStore()

    private let service = "com.openavatar.app"

    enum Key: String, CaseIterable {
        case anthropicAPIKey = "llm.anthropic"
        case openAIAPIKey = "llm.openai"
        case geminiAPIKey = "llm.gemini"
        case cloudSTTAPIKey = "stt.cloud"
        case githubToken = "integration.github"
        case slackUserToken = "integration.slack"
        case linearAPIKey = "integration.linear"
        case smtpPassword = "integration.email.smtp"
        case gmailAccessToken = "integration.email.gmail.access"
        case gmailRefreshToken = "integration.email.gmail.refresh"
    }

#if canImport(Security)
    func set(_ value: String, for key: Key) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
#else
    // Non-Apple platforms (CI linting only): in-memory fallback, never persisted.
    private static var memory: [String: String] = [:]
    func set(_ value: String, for key: Key) { Self.memory[key.rawValue] = value }
    func get(_ key: Key) -> String? { Self.memory[key.rawValue] }
    func delete(_ key: Key) { Self.memory[key.rawValue] = nil }
#endif

    func deleteAll() {
        for key in Key.allCases { delete(key) }
    }

    var hasAnyLLMKey: Bool {
        get(.anthropicAPIKey) != nil || get(.openAIAPIKey) != nil || get(.geminiAPIKey) != nil
    }
}

/// Redacts anything that looks like a secret before it can reach logs or
/// debug output (spec §4.10).
enum Redactor {
    static func redact(_ text: String) -> String {
        var out = text
        let patterns = [
            "sk-[A-Za-z0-9_-]{10,}",          // OpenAI / Anthropic style
            "xox[baprs]-[A-Za-z0-9-]{10,}",   // Slack
            "ghp_[A-Za-z0-9]{20,}",           // GitHub classic PAT
            "github_pat_[A-Za-z0-9_]{20,}",   // GitHub fine-grained PAT
            "lin_api_[A-Za-z0-9]{20,}",       // Linear
            "AIza[A-Za-z0-9_-]{20,}",         // Google API key
            "Bearer\\s+[A-Za-z0-9._-]{16,}"
        ]
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return out
    }
}
