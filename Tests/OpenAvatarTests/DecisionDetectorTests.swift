import XCTest
@testable import OpenAvatar

/// The detector must only surface items the OWNER is responsible for — the app
/// executes on the owner's behalf, so other participants' own to-dos and noise
/// must be dropped.
final class DecisionDetectorTests: XCTestCase {

    private func window(_ pairs: [(AudioSource, String)]) -> [TranscriptSegment] {
        pairs.enumerated().map { i, p in
            TranscriptSegment(text: p.1, t0: Double(i), t1: Double(i) + 1,
                              source: p.0, confidence: 0.9)
        }
    }

    func testKeepsOwnerItemsDropsOthersAndNoise() throws {
        let args = try JSONValue.parse("""
        {"decisions": [
          {"quote": "I'll open a ticket for the pricing bug", "intent": "create_ticket",
           "summary": "Open a ticket for the pricing bug", "assignee": "user",
           "confidence": 0.8, "addressed_to_assistant": false},
          {"quote": "I am typing up a message now to send to the team", "intent": "send_message",
           "summary": "Speaker 6 sends a message to the team", "assignee": "other",
           "confidence": 0.7, "addressed_to_assistant": false},
          {"quote": "maybe we should redesign the page someday", "intent": "other",
           "summary": "Redesign the page", "assignee": "unclear",
           "confidence": 0.3, "addressed_to_assistant": false}
        ]}
        """)
        let decisions = DecisionDetector.parseDecisions(args, callID: UUID(), window: [])
        // Only the owner's own commitment survives.
        XCTAssertEqual(decisions.map(\.summary), ["Open a ticket for the pricing bug"])
    }

    func testKeepsTaskAssignedToOwnerBySomeoneElse() throws {
        // "you need to add this to Linear asap" — said by another party but the
        // model attributes ownership to the user.
        let args = try JSONValue.parse("""
        {"decisions": [
          {"quote": "you need to add this ticket to Linear asap", "intent": "create_ticket",
           "summary": "Add the ticket to Linear", "assignee": "user",
           "confidence": 0.75, "addressed_to_assistant": false}
        ]}
        """)
        let decisions = DecisionDetector.parseDecisions(args, callID: UUID(), window: [])
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.intent, .createTicket)
    }

    func testDropsLowConfidenceOwnerItems() throws {
        let args = try JSONValue.parse("""
        {"decisions": [
          {"quote": "I guess I could look at that at some point", "intent": "other",
           "summary": "Look at that", "assignee": "user",
           "confidence": 0.2, "addressed_to_assistant": false}
        ]}
        """)
        XCTAssertTrue(DecisionDetector.parseDecisions(args, callID: UUID(), window: []).isEmpty)
    }
}
