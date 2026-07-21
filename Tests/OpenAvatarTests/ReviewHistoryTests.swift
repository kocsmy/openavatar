import XCTest
@testable import OpenAvatar

/// Re-opening a past call's review must show only still-unhandled items.
/// Regression: it loaded every decision ever detected on the call, resurrecting
/// items the user had already approved or dismissed.
final class ReviewHistoryTests: XCTestCase {

    private func decision(_ summary: String, callID: UUID,
                          status: DecisionStatus = .detected) -> Decision {
        var d = Decision(callID: callID, quote: "q: \(summary)", intent: .createTicket,
                         summary: summary, assigneeHint: nil, confidence: 0.8,
                         addressedToAssistant: false, source: .mic)
        d.status = status
        return d
    }

    func testAwaitingReviewKeepsOnlyUntouchedItems() {
        let callID = UUID()
        let all = [
            decision("untouched", callID: callID),                       // .detected
            decision("was approved", callID: callID, status: .approved),
            decision("was edited+approved", callID: callID, status: .edited),
            decision("was dismissed", callID: callID, status: .dismissed),
            decision("was executed", callID: callID, status: .executed),
            decision("was reverted", callID: callID, status: .reverted),
            decision("was done by the user", callID: callID, status: .done)
        ]
        XCTAssertEqual(all.awaitingReview.map(\.summary), ["untouched"])
    }

    func testMarkedDoneRoundTripsAndStaysGone() throws {
        // One-click "I did it myself": the item leaves the review permanently,
        // with no dismiss reason (it was a correct detection, not a misfire).
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Zoom")
        let item = decision("send the email", callID: callID)
        try store.insert(item)

        try store.updateDecisionStatus(item.id, status: .done)

        let reloaded = try store.decisions(callID: callID)
        XCTAssertTrue(reloaded.awaitingReview.isEmpty)
        let stored = try XCTUnwrap(reloaded.first { $0.id == item.id })
        XCTAssertEqual(stored.status, .done)
        XCTAssertNil(stored.dismissReason)
    }

    func testHandledItemsDoNotResurrectThroughTheStore() throws {
        // Full round-trip: detect three items, handle two in a "review", then
        // re-load the call from history — only the untouched one comes back.
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Zoom")

        let untouched = decision("still open", callID: callID)
        let dismissed = decision("dismissed in review", callID: callID)
        let approved = decision("approved in review", callID: callID)
        for d in [untouched, dismissed, approved] { try store.insert(d) }

        // The user's earlier review actions:
        try store.updateDecisionStatus(dismissed.id, status: .dismissed,
                                       dismissReason: .notActionable)
        try store.updateDecisionStatus(approved.id, status: .approved)

        // Re-opening from history:
        let reloaded = try store.decisions(callID: callID).awaitingReview
        XCTAssertEqual(reloaded.map(\.id), [untouched.id])
    }
}
