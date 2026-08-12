import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Onboarding surface: the first-run setup steps.
///
/// Most steps just drive the settings bridge (transcriptionMode, assistantName,
/// routes, secrets, …) — this bridge only covers what SettingsBridge doesn't:
/// the microphone TCC prompt, the one-time baseline metric, resetting the
/// trust matrix to its defaults, and marking onboarding complete.
///
/// Returns nil for any method that isn't its own — AppBridge tries the next
/// bridge. The TypeScript half of this contract lives in
/// web/src/lib/types/onboarding.ts.
@MainActor
final class OnboardingBridge {
    private let app = AppState.shared
    private let settings = SettingsStore.shared

    func handle(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        case "onboarding.requestMicrophone": return await requestMicrophone()
        case "onboarding.openMicrophoneSettings": return openMicrophoneSettings()
        case "onboarding.setBaseline": return try setBaseline(params)
        case "onboarding.resetTrustDefaults": return resetTrustDefaults()
        case "onboarding.finish": return finish()
        default: return nil
        }
    }

    // MARK: Permissions (PermissionsStep, spec §4.10)

    /// Same request the native step made: `AVCaptureDevice.requestAccess`
    /// wrapped for the bridge's async signature. macOS only prompts the user
    /// once per install — a repeat call just resolves with the last answer.
    private func requestMicrophone() async -> JSONValue {
#if canImport(AVFoundation)
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        return .object(["granted": .bool(granted)])
#else
        return .object(["granted": .bool(false)])
#endif
    }

    /// Deep-links the same pane the native step opened once a request comes
    /// back denied — requesting again would silently no-op instead of prompting.
    private func openMicrophoneSettings() -> JSONValue {
#if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
#endif
        return .object([:])
    }

    // MARK: Baseline (BaselineAndFinishStep, PRD §7)

    private func setBaseline(_ params: JSONValue) throws -> JSONValue {
        guard let minutes = params["minutes"]?.numberValue else {
            throw AppError.parsing("onboarding.setBaseline needs minutes")
        }
        settings.adminMinutesBaseline = Int(minutes)
        try? MetricsRecorder(store: app.store).setBaseline(minutes: Int(minutes))
        return .object([:])
    }

    // MARK: Trust defaults (TrustStep)

    private func resetTrustDefaults() -> JSONValue {
        settings.trustMatrix = .defaults
        return .object([:])
    }

    // MARK: Finish

    private func finish() -> JSONValue {
        settings.onboardingComplete = true
        return .object([:])
    }
}
