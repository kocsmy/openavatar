import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Call-detection heuristic (spec §4.1): a known call app is running.
/// v1 uses this to *suggest* starting capture (menu-bar highlight), never to
/// auto-record — the user always flips the toggle, keeping recording state
/// legible and consented.
final class CallDetector {
    /// Known call apps; browsers are excluded from auto-suggest in v1 because
    /// "browser is running" is not a call signal.
    static let callAppBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",   // Slack (huddles)
        "com.cisco.webexmeetingsapp",
        "com.ringcentral.RingCentral",
        "com.readdle.smartemail-Mac"
    ]

    struct DetectedCall {
        let appName: String
        let bundleID: String
    }

    func detectRunningCallApp() -> DetectedCall? {
#if canImport(AppKit)
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, Self.callAppBundleIDs.contains(bundleID) {
                return DetectedCall(appName: app.localizedName ?? bundleID, bundleID: bundleID)
            }
        }
#endif
        return nil
    }
}
