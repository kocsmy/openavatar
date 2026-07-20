import Foundation

/// Identifies which app is hosting the current call (spec §4.1).
///
/// Signal: which processes have the MICROPHONE open (AudioProcessInspector) —
/// ground truth, unlike the old "is a call app running?" scan that labeled
/// every call "Slack" because Slack is always running. Browser-hosted calls
/// (Google Meet etc.) are refined with the current calendar event's
/// conferencing service. Used both to label saved calls and to suggest
/// starting capture — never to auto-record.
final class CallDetector {
    /// Known call apps, mapped to the display name we store on calls.
    static let callAppNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.ringcentral.RingCentral": "RingCentral",
        "com.apple.FaceTime": "FaceTime",
        "com.hnc.Discord": "Discord"
    ]

    /// Browsers — a browser with the mic open means a web call (Meet, web
    /// Zoom, …); the calendar event usually knows which service.
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium"
    ]

    struct DetectedCall: Equatable {
        let appName: String
        let bundleID: String
    }

    /// The app hosting the call right now, or nil when no app has the mic
    /// open (= no call). `conferenceService` (from the calendar event) names
    /// browser-hosted calls properly.
    func detectActiveCall(conferenceService: String? = nil) -> DetectedCall? {
        Self.classify(micApps: AudioProcessInspector.micActiveApps(),
                      conferenceService: conferenceService)
    }

    /// Pure resolution, unit-tested: known call apps beat browsers beat
    /// anything else with the mic open.
    static func classify(micApps: [AudioProcessInspector.MicActiveApp],
                         conferenceService: String?) -> DetectedCall? {
        if let known = micApps.first(where: { callAppNames[$0.bundleID] != nil }) {
            return DetectedCall(appName: callAppNames[known.bundleID]!,
                                bundleID: known.bundleID)
        }
        if let browser = micApps.first(where: { browserBundleIDs.contains($0.bundleID) }) {
            let name = conferenceService ?? "\(browser.name) call"
            return DetectedCall(appName: name, bundleID: browser.bundleID)
        }
        // Some other app holds the mic (dictation tools, unknown call apps):
        // better its real name than a wrong guess.
        if let other = micApps.first {
            return DetectedCall(appName: other.name, bundleID: other.bundleID)
        }
        return nil
    }
}
