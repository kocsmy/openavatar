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
}
