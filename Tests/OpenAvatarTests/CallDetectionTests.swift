import XCTest
@testable import OpenAvatar

/// Call-app attribution. Regression: every call was labeled "Slack" because
/// detection checked which known app was RUNNING (Slack always is) instead of
/// which app holds the microphone.
final class CallDetectionTests: XCTestCase {

    private func app(_ bundleID: String, _ name: String) -> AudioProcessInspector.MicActiveApp {
        .init(bundleID: bundleID, name: name)
    }

    // MARK: Mic-owner classification

    func testKnownCallAppWinsEvenWhenOthersHoldTheMic() {
        let detected = CallDetector.classify(
            micApps: [app("com.google.Chrome", "Chrome"),
                      app("us.zoom.xos", "zoom.us")],
            conferenceService: nil)
        XCTAssertEqual(detected?.appName, "Zoom")
    }

    func testBrowserCallNamedByCalendarConferenceService() {
        let detected = CallDetector.classify(
            micApps: [app("com.google.Chrome", "Google Chrome")],
            conferenceService: "Google Meet")
        XCTAssertEqual(detected?.appName, "Google Meet")
    }

    func testBrowserCallWithoutCalendarFallsBackToBrowserName() {
        let detected = CallDetector.classify(
            micApps: [app("com.apple.Safari", "Safari")],
            conferenceService: nil)
        XCTAssertEqual(detected?.appName, "Safari call")
    }

    func testUnknownMicHolderUsesItsRealName() {
        let detected = CallDetector.classify(
            micApps: [app("com.example.newvoip", "NewVoIP")],
            conferenceService: nil)
        XCTAssertEqual(detected?.appName, "NewVoIP")
    }

    func testNoMicActivityMeansNoCall() {
        // Slack merely being open must never produce a call label again.
        XCTAssertNil(CallDetector.classify(micApps: [], conferenceService: nil))
    }

    func testSlackOnlyWinsWhenItHoldsTheMic() {
        let detected = CallDetector.classify(
            micApps: [app("com.tinyspeck.slackmacgap", "Slack")],
            conferenceService: nil)
        XCTAssertEqual(detected?.appName, "Slack")
    }

    // MARK: Helper processes (regression: raw bundle ids in the UI)

    func testSlackHelperProcessMatchesSlack() {
        // The mic is held by "<parent id>.helper", which isn't an
        // NSRunningApplication — exact matching showed the raw bundle id.
        let detected = CallDetector.classify(
            micApps: [app("com.tinyspeck.slackmacgap.helper",
                          "com.tinyspeck.slackmacgap.helper")],
            conferenceService: nil)
        XCTAssertEqual(detected?.appName, "Slack")
        XCTAssertEqual(detected?.strongCallSignal, true)
    }

    func testArcHelperMatchesDespiteCaseAndSuffix() {
        // Arc's helper reports "company.thebrowser.browser.helper" while the
        // known browser id is "company.thebrowser.Browser".
        let weak = CallDetector.classify(
            micApps: [app("company.thebrowser.browser.helper",
                          "company.thebrowser.browser.helper")],
            conferenceService: nil)
        XCTAssertEqual(weak?.appName, "Arc call")
        XCTAssertEqual(weak?.strongCallSignal, false)

        let meeting = CallDetector.classify(
            micApps: [app("company.thebrowser.browser.helper",
                          "company.thebrowser.browser.helper")],
            conferenceService: "Google Meet")
        XCTAssertEqual(meeting?.appName, "Google Meet")
        XCTAssertEqual(meeting?.strongCallSignal, true)
    }

    func testUnknownHelperBundleIDGetsAReadableName() {
        // Never show reverse-DNS in the UI, even for apps we don't know.
        let detected = CallDetector.classify(
            micApps: [app("com.example.coolvoip.helper", "com.example.coolvoip.helper")],
            conferenceService: nil)
        XCTAssertEqual(detected?.appName, "Coolvoip")
    }

    func testChromeCanaryPrefersItsExactEntryOverChromePrefix() {
        let detected = CallDetector.classify(
            micApps: [app("com.google.Chrome.canary", "Chrome Canary")],
            conferenceService: nil)
        XCTAssertEqual(detected?.appName, "Chrome Canary call")
    }

    // MARK: Strong vs weak signals (auto-start gate)

    func testKnownCallAppIsAStrongSignal() {
        let detected = CallDetector.classify(
            micApps: [app("us.zoom.xos", "zoom.us")], conferenceService: nil)
        XCTAssertEqual(detected?.strongCallSignal, true)
    }

    func testBrowserDuringCalendarMeetingIsStrong() {
        let detected = CallDetector.classify(
            micApps: [app("com.google.Chrome", "Google Chrome")],
            conferenceService: "Google Meet")
        XCTAssertEqual(detected?.strongCallSignal, true)
    }

    func testBrowserWithoutCalendarIsWeak() {
        // A website using the mic isn't necessarily a call — suggest, don't record.
        let detected = CallDetector.classify(
            micApps: [app("com.apple.Safari", "Safari")], conferenceService: nil)
        XCTAssertEqual(detected?.strongCallSignal, false)
    }

    func testUnknownMicHolderIsWeak() {
        // Dictation tools etc. must never trigger auto-recording.
        let detected = CallDetector.classify(
            micApps: [app("com.example.dictate", "SuperDictate")], conferenceService: nil)
        XCTAssertEqual(detected?.strongCallSignal, false)
    }

    // MARK: Conference-service extraction from calendar events

    func testConferenceSolutionNameWins() throws {
        let json = try JSONValue.parse(#"""
            {"conferenceData": {"conferenceSolution": {"name": "Google Meet"},
                                "entryPoints": [{"uri": "https://meet.google.com/abc"}]}}
            """#)
        XCTAssertEqual(GoogleCalendarClient.conferenceService(of: json), "Google Meet")
    }

    func testZoomLinkInLocationSniffed() throws {
        let json = try JSONValue.parse(#"""
            {"location": "https://acme.zoom.us/j/123456"}
            """#)
        XCTAssertEqual(GoogleCalendarClient.conferenceService(of: json), "Zoom")
    }

    func testHangoutLinkSniffed() throws {
        let json = try JSONValue.parse(#"""
            {"hangoutLink": "https://meet.google.com/xyz-abcd-efg"}
            """#)
        XCTAssertEqual(GoogleCalendarClient.conferenceService(of: json), "Google Meet")
    }

    func testEventWithoutMeetingLinkHasNoService() throws {
        let json = try JSONValue.parse(#"{"location": "Conference room 4B"}"#)
        XCTAssertNil(GoogleCalendarClient.conferenceService(of: json))
    }

    // MARK: Store relabeling

    func testUpdateCallAppRelabelsTheRecord() throws {
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Slack")
        try store.updateCallApp(callID, app: "Google Meet")
        let call = try XCTUnwrap(store.listCalls(limit: 1).first)
        XCTAssertEqual(call.app, "Google Meet")
    }

    func testUserNotesRoundTrip() throws {
        // The call window's own-notes scratchpad autosaves onto the call.
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Zoom")
        XCTAssertEqual(try store.callUserNotes(callID), "")
        try store.updateCallUserNotes(callID, text: "- ask Ben about pricing")
        XCTAssertEqual(try store.callUserNotes(callID), "- ask Ben about pricing")
        let record = try XCTUnwrap(store.listCalls(limit: 1).first)
        XCTAssertEqual(record.userNotes, "- ask Ben about pricing")
    }
}
