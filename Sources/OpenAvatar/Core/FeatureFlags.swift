import Foundation

/// v1.x features stubbed behind flags (spec §2 Non-Goals). All default false
/// and there is deliberately no UI to enable them in v1.0.
struct FeatureFlags {
    static var telegramBridge: Bool {
        UserDefaults.standard.bool(forKey: "flag.telegramBridge")
    }
    static var screenContextOCR: Bool {
        UserDefaults.standard.bool(forKey: "flag.screenContextOCR")
    }
    static var slackInteractiveApprovals: Bool {
        UserDefaults.standard.bool(forKey: "flag.slackInteractiveApprovals")
    }
    static var semanticContext: Bool {
        UserDefaults.standard.bool(forKey: "flag.semanticContext")
    }
}
