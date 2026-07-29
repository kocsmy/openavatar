import Foundation

/// Identifies which app is hosting the current call (spec §4.1).
///
/// Signal: which processes have the MICROPHONE open (AudioProcessInspector) —
/// ground truth, unlike the old "is a call app running?" scan that labeled
/// every call "Slack" because Slack is always running. Browser-hosted calls
/// (Google Meet etc.) are refined with the current calendar event's
/// conferencing service. Used both to label saved calls and to suggest
/// starting capture — never to auto-record.
///
/// Matching is case-insensitive and prefix-aware: the mic is often held by a
/// HELPER process ("com.tinyspeck.slackmacgap.helper",
/// "company.thebrowser.browser.helper") whose bundle id is the parent app's
/// id plus a suffix — exact matching left those showing as raw bundle ids.
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

    /// Browsers with display names — a browser with the mic open means a web
    /// call (Meet, web Zoom, …); the calendar event usually names the service.
    static let browserNames: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.canary": "Chrome Canary",
        "com.apple.Safari": "Safari",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.edgemac": "Edge",
        "com.brave.Browser": "Brave",
        "company.thebrowser.Browser": "Arc",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "org.chromium.Chromium": "Chromium"
    ]

    struct DetectedCall: Equatable {
        let appName: String
        let bundleID: String
        /// True when this is unambiguously a call (a known call app holds the
        /// mic, or a browser does during a calendar event with a meeting
        /// link). Auto-start requires a strong signal; a random app opening
        /// the mic only gets the suggestion banner / floating prompt.
        var strongCallSignal: Bool = false
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
        for app in micApps {
            if let name = lookup(app.bundleID, in: callAppNames) {
                return DetectedCall(appName: name, bundleID: app.bundleID,
                                    strongCallSignal: true)
            }
        }
        for app in micApps {
            if let browser = lookup(app.bundleID, in: browserNames) {
                return DetectedCall(appName: conferenceService ?? "\(browser) call",
                                    bundleID: app.bundleID,
                                    strongCallSignal: conferenceService != nil)
            }
        }
        // Some other app holds the mic (dictation tools, unknown call apps):
        // better its real name than a wrong guess.
        if let other = micApps.first {
            return DetectedCall(appName: humanName(other), bundleID: other.bundleID)
        }
        return nil
    }

    /// Case-insensitive lookup that also matches helper processes: a bundle id
    /// equal to a known id, or extending it ("<known>.helper", "<known>.gpu").
    /// Exact match wins; otherwise the longest matching known id.
    static func lookup(_ bundleID: String, in table: [String: String]) -> String? {
        let lower = bundleID.lowercased()
        if let exact = table.first(where: { $0.key.lowercased() == lower }) {
            return exact.value
        }
        return table
            .filter { lower.hasPrefix($0.key.lowercased() + ".") }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    /// Best display name for an unrecognized mic holder. Helper processes
    /// report raw bundle ids ("com.example.coolvoip.helper") — derive a
    /// readable word instead of showing reverse-DNS in the UI.
    static func humanName(_ app: AudioProcessInspector.MicActiveApp) -> String {
        guard app.name == app.bundleID, app.name.contains(".") else { return app.name }
        let generic: Set<String> = ["helper", "renderer", "plugin", "gpu", "app", "service"]
        var parts = app.bundleID.lowercased().split(separator: ".").map(String.init)
        while let last = parts.last, generic.contains(last) { parts.removeLast() }
        guard let core = parts.last, !core.isEmpty else { return app.name }
        return core.prefix(1).uppercased() + core.dropFirst()
    }
}
