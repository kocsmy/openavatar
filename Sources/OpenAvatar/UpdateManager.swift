import Foundation
#if canImport(Sparkle)
import Sparkle

/// Background auto-updates via Sparkle: checks the GitHub Releases appcast,
/// downloads new versions in the background, and prompts for a relaunch when
/// one is ready — no more manual DMG downloads after the first install.
/// Feed URL and EdDSA public key live in Info.plist (SUFeedURL/SUPublicEDKey);
/// updates are signed in CI with the matching private key.
@MainActor
final class UpdateManager {
    static let shared = UpdateManager()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
#else
/// Placeholder for non-macOS lint builds.
@MainActor
final class UpdateManager {
    static let shared = UpdateManager()
    func checkForUpdates() {}
    var currentVersion: String { "dev" }
}
#endif
