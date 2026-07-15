import XCTest
@testable import OpenAvatar

/// Guards the popover-sizing regression: short content must NOT scroll (which
/// left a huge blank area in v1.7.3), and tall content MUST scroll (or it
/// overflows the screen).
final class PopoverLayoutTests: XCTestCase {

    private func metrics(callSuggestion: Bool = false, error: Bool = false,
                         suggestions: Int = 0, approvals: Int = 0,
                         detected: Int = 0, executed: Int = 0,
                         empty: Bool = false) -> PopoverLayout.Metrics {
        PopoverLayout.Metrics(hasCallSuggestion: callSuggestion, hasError: error,
                              suggestions: suggestions, approvals: approvals,
                              detected: detected, executed: executed, isEmpty: empty)
    }

    func testEmptyStateDoesNotScroll() {
        XCTAssertFalse(metrics(empty: true).needsScroll)
    }

    func testIdleWithCallSuggestionDoesNotScroll() {
        // The exact regression screenshot: idle, "Slack looks active" banner only.
        XCTAssertFalse(metrics(callSuggestion: true, empty: true).needsScroll)
        XCTAssertFalse(metrics(callSuggestion: true).needsScroll)
    }

    func testSingleApprovalFits() {
        XCTAssertFalse(metrics(approvals: 1).needsScroll)
    }

    func testAFewDetectedItemsFit() {
        XCTAssertFalse(metrics(detected: 3).needsScroll)
    }

    func testTwoApprovalsScroll() {
        XCTAssertTrue(metrics(approvals: 2).needsScroll)
    }

    func testBusyReviewScrolls() {
        // suggestion + approval + 3 detected — the "breaks completely" case.
        XCTAssertTrue(metrics(suggestions: 1, approvals: 1, detected: 3).needsScroll)
    }

    func testErrorPlusContentScrolls() {
        XCTAssertTrue(metrics(error: true, detected: 3, executed: 3).needsScroll)
    }
}
