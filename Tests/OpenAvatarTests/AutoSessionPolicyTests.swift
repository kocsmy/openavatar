import XCTest
@testable import OpenAvatar

/// The auto start/stop state machine around calls. The stakes: never record
/// against the user's explicit stop, never let a mic blip end a session, and
/// never let a random non-call app trigger recording (that part lives in
/// CallDetector.strongCallSignal, tested in CallDetectionTests).
final class AutoSessionPolicyTests: XCTestCase {

    func testStartsWhenCallAppearsAndEnabled() {
        var p = AutoSessionPolicy()
        XCTAssertEqual(p.tick(enabled: true, isListening: false, autoStarted: false,
                              callActive: false), .none)
        XCTAssertEqual(p.tick(enabled: true, isListening: false, autoStarted: false,
                              callActive: true), .start)
    }

    func testNeverStartsWhenDisabled() {
        var p = AutoSessionPolicy()
        XCTAssertEqual(p.tick(enabled: false, isListening: false, autoStarted: false,
                              callActive: true), .none)
    }

    func testStopsOnlyAfterConsecutiveMissedTicks() {
        var p = AutoSessionPolicy()
        _ = p.tick(enabled: true, isListening: false, autoStarted: false, callActive: true) // .start
        // Call ongoing, then a one-tick mic blip, then back: must not stop.
        XCTAssertEqual(p.tick(enabled: true, isListening: true, autoStarted: true, callActive: true), .none)
        XCTAssertEqual(p.tick(enabled: true, isListening: true, autoStarted: true, callActive: false), .none)
        XCTAssertEqual(p.tick(enabled: true, isListening: true, autoStarted: true, callActive: true), .none)
        // Call actually over: stops after ticksToStop consecutive misses.
        for _ in 1..<AutoSessionPolicy.ticksToStop {
            XCTAssertEqual(p.tick(enabled: true, isListening: true, autoStarted: true, callActive: false), .none)
        }
        XCTAssertEqual(p.tick(enabled: true, isListening: true, autoStarted: true, callActive: false), .stop)
    }

    func testManualSessionWithNoCallIsNeverAutoStopped() {
        // Dictation / testing: nothing ever holds the mic — recording is the
        // user's business, never end it for them.
        var p = AutoSessionPolicy()
        p.sessionStarted()
        for _ in 0..<10 {
            XCTAssertEqual(p.tick(enabled: true, isListening: true, autoStarted: false,
                                  callActive: false), .none)
        }
    }

    func testManualSessionStopsOnceItsCallEnds() {
        // Regression: manually started call sessions used to record forever
        // after the call ended (94-minute record for a 20-minute meeting).
        var p = AutoSessionPolicy()
        p.sessionStarted()
        XCTAssertEqual(p.tick(enabled: true, isListening: true, autoStarted: false, callActive: true), .none)
        for _ in 1..<AutoSessionPolicy.ticksToStop {
            XCTAssertEqual(p.tick(enabled: true, isListening: true, autoStarted: false, callActive: false), .none)
        }
        XCTAssertEqual(p.tick(enabled: true, isListening: true, autoStarted: false, callActive: false), .stop)
    }

    func testCallSightingDoesNotCarryAcrossSessions() {
        var p = AutoSessionPolicy()
        p.sessionStarted()
        _ = p.tick(enabled: true, isListening: true, autoStarted: false, callActive: true)
        p.userStopped(callStillActive: false)
        // New manual session, no call this time: must never auto-stop.
        p.sessionStarted()
        for _ in 0..<10 {
            XCTAssertEqual(p.tick(enabled: true, isListening: true, autoStarted: false,
                                  callActive: false), .none)
        }
    }

    func testUserStopMidCallDisarmsUntilCallEnds() {
        var p = AutoSessionPolicy()
        _ = p.tick(enabled: true, isListening: false, autoStarted: false, callActive: true) // .start
        p.userStopped(callStillActive: true)
        // Same call still going: must NOT restart against the user's wish.
        XCTAssertEqual(p.tick(enabled: true, isListening: false, autoStarted: false, callActive: true), .none)
        XCTAssertEqual(p.tick(enabled: true, isListening: false, autoStarted: false, callActive: true), .none)
        // Call ends → re-arms; the NEXT call auto-starts again.
        XCTAssertEqual(p.tick(enabled: true, isListening: false, autoStarted: false, callActive: false), .none)
        XCTAssertEqual(p.tick(enabled: true, isListening: false, autoStarted: false, callActive: true), .start)
    }

    func testUserStopAfterCallEndedStaysArmed() {
        var p = AutoSessionPolicy()
        p.userStopped(callStillActive: false)
        XCTAssertEqual(p.tick(enabled: true, isListening: false, autoStarted: false,
                              callActive: true), .start)
    }
}

/// The block-level Markdown parser behind the meeting-notes view.
final class MarkdownNoteTests: XCTestCase {

    func testParsesHeadingsBulletsAndText() {
        let blocks = MarkdownNote.parse("""
        ## June ARR Summary
        - Self-serve landed at $612k
        * Churn still an issue
        Some plain line.

        ### Next steps
        """)
        XCTAssertEqual(blocks, [
            .heading("June ARR Summary"),
            .bullet("Self-serve landed at $612k", 0),
            .bullet("Churn still an issue", 0),
            .text("Some plain line."),
            .heading("Next steps")
        ])
    }

    func testBlankAndWhitespaceLinesAreDropped() {
        XCTAssertEqual(MarkdownNote.parse("\n   \n\n"), [])
    }

    func testIndentedBulletsCarryTheirNestingLevel() {
        // Granola-style sub-bullets: supporting detail sits under its parent.
        XCTAssertEqual(MarkdownNote.parse("""
        - Cookie consent caused the GA4 traffic drop
          - Bots don't accept cookies, so bot traffic is now excluded
        \t- Unique visitors dropped from ~50k to ~20k
        """), [
            .bullet("Cookie consent caused the GA4 traffic drop", 0),
            .bullet("Bots don't accept cookies, so bot traffic is now excluded", 1),
            .bullet("Unique visitors dropped from ~50k to ~20k", 1)
        ])
    }

    func testNestingIsCappedAtTwoLevels() {
        XCTAssertEqual(MarkdownNote.parse("        - very deep"),
                       [.bullet("very deep", 2)])
    }
}

/// The floating "Take notes?" prompt: shows exactly when a call is happening
/// that auto-start will NOT handle, and never nags after a dismissal.
final class CallPromptPolicyTests: XCTestCase {

    func testWeakSignalPromptsEvenWithAutoStartOn() {
        // Browser holding the mic without a calendar meeting: auto-start
        // ignores it, so the prompt is the only way in.
        XCTAssertTrue(CallPromptPolicy.shouldPrompt(
            isListening: false, callDetected: true, strongSignal: false,
            autoStartEnabled: true, dismissed: false))
    }

    func testStrongSignalWithAutoStartOnStaysQuiet() {
        // Auto-start is about to handle it — prompting too would double up.
        XCTAssertFalse(CallPromptPolicy.shouldPrompt(
            isListening: false, callDetected: true, strongSignal: true,
            autoStartEnabled: true, dismissed: false))
    }

    func testStrongSignalWithAutoStartOffPrompts() {
        XCTAssertTrue(CallPromptPolicy.shouldPrompt(
            isListening: false, callDetected: true, strongSignal: true,
            autoStartEnabled: false, dismissed: false))
    }

    func testNeverPromptsWhileListeningOrWithoutACall() {
        XCTAssertFalse(CallPromptPolicy.shouldPrompt(
            isListening: true, callDetected: true, strongSignal: false,
            autoStartEnabled: true, dismissed: false))
        XCTAssertFalse(CallPromptPolicy.shouldPrompt(
            isListening: false, callDetected: false, strongSignal: false,
            autoStartEnabled: true, dismissed: false))
    }

    func testDismissalSilencesThePrompt() {
        XCTAssertFalse(CallPromptPolicy.shouldPrompt(
            isListening: false, callDetected: true, strongSignal: false,
            autoStartEnabled: true, dismissed: true))
    }
}
