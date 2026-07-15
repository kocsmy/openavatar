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

    // MARK: Enum-keyed accessors (built-in secrets)

    func set(_ value: String, for key: Key) { setRaw(value, account: key.rawValue) }
    func get(_ key: Key) -> String? { getRaw(account: key.rawValue) }
    func delete(_ key: Key) { deleteRaw(account: key.rawValue) }

    func deleteAll() {
        for key in Key.allCases { delete(key) }
    }

    var hasAnyLLMKey: Bool {
        return self.get(.anthropicAPIKey) != nil
            || self.get(.openAIAPIKey) != nil
            || self.get(.geminiAPIKey) != nil
    }

    // MARK: Dynamic secrets (manifest/MCP integrations — arbitrary IDs)

    func setSecret(_ value: String, forIntegration id: String) {
        setRaw(value, account: "dynamic.integration.\(id)")
    }

    func secret(forIntegration id: String) -> String? {
        getRaw(account: "dynamic.integration.\(id)")
    }

    func deleteSecret(forIntegration id: String) {
        deleteRaw(account: "dynamic.integration.\(id)")
    }

    // MARK: Raw primitives

#if canImport(Security)
    /// Use the modern data-protection keychain, NOT the legacy file-based
    /// login keychain. The legacy keychain gates access with a per-code-
    /// signature ACL and shows the "wants to use your confidential
    /// information" dialog; because the app is ad-hoc signed, its signature
    /// changes on every build/auto-update, so "Always Allow" never sticks and
    /// the prompt returns after each update. The data-protection keychain
    /// scopes access to the app's keychain-access-group entitlement instead,
    /// so the app reads its own items silently and updates don't re-prompt.
    private func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Prefer the data-protection keychain; the legacy fallback omits this so
        // the app still works when the keychain-access-group entitlement is
        // absent or ignored (e.g. an ad-hoc build whose entitlement macOS drops).
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func setRaw(_ value: String, account: String) {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        func write(dataProtection: Bool) -> OSStatus {
            let query = baseQuery(account: account, dataProtection: dataProtection)
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add.merge(attributes) { _, new in new }
                status = SecItemAdd(add as CFDictionary, nil)
            }
            return status
        }
        // errSecMissingEntitlement (-34018): the data-protection keychain
        // rejected us for lacking a keychain-access-group entitlement — retry
        // against the legacy keychain so ad-hoc builds still store secrets.
        if write(dataProtection: true) == errSecMissingEntitlement {
            _ = write(dataProtection: false)
        }
    }

    private func getRaw(account: String) -> String? {
        func read(dataProtection: Bool) -> (OSStatus, String?) {
            var query = baseQuery(account: account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else { return (status, nil) }
            return (status, String(data: data, encoding: .utf8))
        }
        let (status, value) = read(dataProtection: true)
        if status == errSecMissingEntitlement {
            return read(dataProtection: false).1
        }
        return value
    }

    private func deleteRaw(account: String) {
        // Delete from both keychains so a secret can't linger in whichever store
        // an earlier build wrote it to.
        let status = SecItemDelete(baseQuery(account: account, dataProtection: true) as CFDictionary)
        if status == errSecMissingEntitlement {
            SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
        }
    }
#else
    // Non-Apple platforms (CI linting only): in-memory fallback, never persisted.
    private static var memory: [String: String] = [:]
    private func setRaw(_ value: String, account: String) { Self.memory[account] = value }
    private func getRaw(account: String) -> String? { Self.memory[account] }
    private func deleteRaw(account: String) { Self.memory[account] = nil }
#endif
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
