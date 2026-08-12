import Foundation

/// The JSON method router behind every web surface. Each window gets its own
/// AppBridge; the sub-bridges are split one per surface so they stay small and
/// own their own contract half (the TypeScript half lives in
/// web/src/lib/types/). A sub-bridge returns nil for a method that isn't its
/// own, and the router moves on.
@MainActor
final class AppBridge {
    private let settings = SettingsBridge()
    private let home = HomeBridge()
    private let metrics = MetricsBridge()
    private let meetings = MeetingsBridge()
    private let followUps = FollowUpsBridge()
    private let call = CallBridge()
    private let onboarding = OnboardingBridge()
    private let menu = MenuBridge()

    /// Window-shaped requests the page can't answer for itself. Set by the
    /// host that owns this surface.
    private let onResize: ((CGFloat) -> Void)?
    private let onClose: (() -> Void)?

    init(onResize: ((CGFloat) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.onResize = onResize
        self.onClose = onClose
    }

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        if let result = try await ui(method: method, params: params) { return result }
        if let result = try await settings.handle(method: method, params: params) { return result }
        if let result = try await home.handle(method: method, params: params) { return result }
        if let result = try await metrics.handle(method: method, params: params) { return result }
        if let result = try await meetings.handle(method: method, params: params) { return result }
        if let result = try await followUps.handle(method: method, params: params) { return result }
        if let result = try await call.handle(method: method, params: params) { return result }
        if let result = try await onboarding.handle(method: method, params: params) { return result }
        if let result = try await menu.handle(method: method, params: params) { return result }
        throw AppError.integration("Unknown bridge method: \(method)")
    }

    // MARK: Window plumbing

    private func ui(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        case "ui.resize":
            if let height = params["height"]?.numberValue { onResize?(CGFloat(height)) }
            return .object([:])
        case "window.open":
#if canImport(AppKit) && canImport(WebKit)
            let section = params["section"]?.stringValue
            switch params["window"]?.stringValue {
            case "settings": WebWindowController.shared.show(.settings, section: section)
            case "main": WebWindowController.shared.show(.main, section: section)
            case "call": WebWindowController.shared.show(.call)
            case "onboarding": WebWindowController.shared.show(.onboarding)
            default: throw AppError.integration("Unknown window")
            }
#endif
            return .object([:])
        case "window.close":
            onClose?()
            return .object([:])
        default:
            return nil
        }
    }
}
