import XCTest
@testable import OpenAvatar

/// The pre-review dedupe pass: near-identical action items must collapse to
/// the highest-confidence one, distinct items must survive, and the LLM
/// response parser must never let the model empty the whole review.
final class ReviewSanitizerTests: XCTestCase {

    private func decision(_ summary: String, confidence: Double = 0.8,
                          callID: UUID = UUID()) -> Decision {
        Decision(callID: callID, quote: "q: \(summary)", intent: .createTicket,
                 summary: summary, assigneeHint: nil, confidence: confidence,
                 addressedToAssistant: false, source: .mic)
    }

    // MARK: Local pass

    func testExactRewordKeepsHighestConfidence() {
        let strong = decision("Create a Linear ticket for the pricing bug", confidence: 0.9)
        let weak = decision("create a linear ticket for the pricing bug", confidence: 0.5)
        let dropped = ReviewSanitizer.localDuplicates([weak, strong])
        XCTAssertEqual(dropped, [weak.id])
    }

    func testTokenOverlapCatchesPartialReword() {
        // Same task, one word swapped — Jaccard overlap well above 0.6.
        let strong = decision("Fix the pricing bug on the checkout page", confidence: 0.9)
        let weak = decision("Fix the pricing bug on the payment page", confidence: 0.6)
        let dropped = ReviewSanitizer.localDuplicates([strong, weak])
        XCTAssertEqual(dropped, [weak.id])
    }

    func testDistinctTasksAllSurvive() {
        let items = [
            decision("Create a Linear ticket for the onboarding crash"),
            decision("Email Sarah the Q3 revenue numbers"),
            decision("Merge the auth refactor PR")
        ]
        XCTAssertTrue(ReviewSanitizer.localDuplicates(items).isEmpty)
    }

    func testSingleItemNeverDropped() {
        XCTAssertTrue(ReviewSanitizer.localDuplicates([decision("only one")]).isEmpty)
    }

    // MARK: LLM response parsing

    func testParseMapsPrefixesBackToDecisions() throws {
        let a = decision("task a"), b = decision("task b"), c = decision("task c")
        let prefix = String(b.id.uuidString.prefix(8)).lowercased()
        let args = try JSONValue.parse(#"{"duplicate_ids": ["\#(prefix)"]}"#)
        XCTAssertEqual(ReviewSanitizer.parse(args, decisions: [a, b, c]), [b.id])
    }

    func testParseIgnoresUnknownPrefixesAndEmptyStrings() throws {
        let a = decision("task a"), b = decision("task b")
        let args = try JSONValue.parse(#"{"duplicate_ids": ["zzzzzzzz", ""]}"#)
        XCTAssertTrue(ReviewSanitizer.parse(args, decisions: [a, b]).isEmpty)
    }

    func testParseRefusesToDropEverything() throws {
        // Safety valve: a runaway model marking every item as a duplicate is
        // ignored — a review with dupes beats an empty review.
        let a = decision("task a"), b = decision("task b")
        let args = try JSONValue.parse(#"""
            {"duplicate_ids": ["\#(a.id.uuidString.prefix(8))",
                               "\#(b.id.uuidString.prefix(8))"]}
            """#)
        XCTAssertTrue(ReviewSanitizer.parse(args, decisions: [a, b]).isEmpty)
    }
}
