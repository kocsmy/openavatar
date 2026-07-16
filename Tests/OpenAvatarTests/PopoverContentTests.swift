import XCTest
@testable import OpenAvatar

/// Structure-snapshot tests for the menu-bar popover's Actions tab. The view
/// renders directly from PopoverContent.sections, so asserting the section list
/// here locks in exactly what the user sees — the section order and which
/// states show the empty view. Sizing is no longer testable logic by design:
/// the content region is one constant height (PopoverLayout.contentHeight) in
/// every state, because every popover layout bug (footer overlap, gap under
/// the icon, blank space) came from dynamic sizing.
final class PopoverContentTests: XCTestCase {

    private func content(callSuggestion: Bool = false, error: Bool = false,
                         suggestions: Int = 0, approvals: Int = 0,
                         detected: Int = 0, executed: Int = 0) -> PopoverContent {
        PopoverContent(hasCallSuggestion: callSuggestion, hasError: error,
                       suggestions: suggestions, approvals: approvals,
                       detected: detected, executed: executed)
    }

    // MARK: Idle / empty states

    func testIdleShowsOnlyEmptyState() {
        let c = content()
        XCTAssertEqual(c.sections, [.empty])
        XCTAssertTrue(c.isEmpty)
    }

    func testIdleWithCallSuggestionShowsBannerAndEmptyState() {
        // The exact state from the overlap screenshot: idle + "Slack looks
        // active" banner. The empty view must still show below the banner.
        let c = content(callSuggestion: true)
        XCTAssertEqual(c.sections, [.callSuggestion, .empty])
        XCTAssertTrue(c.isEmpty)
    }

    // MARK: Populated states

    func testSectionOrderIsStable() {
        let c = content(callSuggestion: true, error: true,
                        suggestions: 1, approvals: 1, detected: 2, executed: 1)
        XCTAssertEqual(c.sections,
                       [.callSuggestion, .error, .suggestions, .approvals, .detected, .executed])
        XCTAssertFalse(c.isEmpty)
    }

    func testEmptyStateNeverCoexistsWithContent() {
        XCTAssertFalse(content(detected: 1).sections.contains(.empty))
        XCTAssertFalse(content(error: true).sections.contains(.empty))
        XCTAssertFalse(content(executed: 1).sections.contains(.empty))
    }

    func testCallSuggestionAloneStillCountsAsEmpty() {
        // The banner is a prompt, not content — dismissing/ignoring it must not
        // hide the "not listening" explanation.
        XCTAssertTrue(content(callSuggestion: true).isEmpty)
    }

    // MARK: Constant-size contract

    func testContentRegionHeightIsASaneConstant() {
        // If this constant ever becomes state-dependent again, stop: dynamic
        // popover sizing is what caused the overlap/gap/blank-space bugs.
        XCTAssertEqual(PopoverLayout.contentHeight, 440)
    }
}
