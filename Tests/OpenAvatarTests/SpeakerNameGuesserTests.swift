import XCTest
@testable import OpenAvatar

final class SpeakerNameGuesserTests: XCTestCase {

    func testParseKeepsConfidentPlausibleNames() throws {
        let args = try JSONValue.parse("""
        {"names": [
          {"speaker": "Speaker 4", "name": "Vasilis", "confidence": 0.9},
          {"speaker": "Speaker 7", "name": "Alexa Smith", "confidence": 0.75}
        ]}
        """)
        let guesses = SpeakerNameGuesser.parse(args)
        XCTAssertEqual(guesses, [
            .init(label: "Speaker 4", name: "Vasilis"),
            .init(label: "Speaker 7", name: "Alexa Smith")
        ])
    }

    func testParseDropsLowConfidenceAndImplausibleNames() throws {
        let args = try JSONValue.parse("""
        {"names": [
          {"speaker": "Speaker 4", "name": "Maybe Bob", "confidence": 0.4},
          {"speaker": "Speaker 5", "name": "unknown", "confidence": 0.9},
          {"speaker": "Speaker 6", "name": "the marketing person on the call", "confidence": 0.9},
          {"speaker": "Speaker 7", "name": "", "confidence": 0.9}
        ]}
        """)
        XCTAssertTrue(SpeakerNameGuesser.parse(args).isEmpty)
    }

    func testParseNeverAssignsSameNameTwiceOrRelabelsSameSpeaker() throws {
        // Two speakers can't both become "Vasilis" (would silently merge people),
        // and one speaker only gets its first name guess.
        let args = try JSONValue.parse("""
        {"names": [
          {"speaker": "Speaker 4", "name": "Vasilis", "confidence": 0.9},
          {"speaker": "Speaker 5", "name": "Vasilis", "confidence": 0.85},
          {"speaker": "Speaker 4", "name": "Andreas", "confidence": 0.8}
        ]}
        """)
        XCTAssertEqual(SpeakerNameGuesser.parse(args),
                       [.init(label: "Speaker 4", name: "Vasilis")])
    }

    func testPerCallSpeakerScoping() throws {
        // speakerProfiles(callID:) returns only the voices heard on that call,
        // in first-heard order — the basis of the per-call roster UI.
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let alice = UUID(), bob = UUID(), stranger = UUID()
        for (id, name, ordinal) in [(alice, "Alice", 1), (bob, nil, 2), (stranger, nil, 3)] {
            try store.insertSpeakerProfile(SpeakerProfile(
                id: id, name: name, ordinal: ordinal, embedding: [1, 0],
                sampleCount: 1, createdAt: now, updatedAt: now))
        }
        let call = try store.startCall(app: nil)
        try store.insert([
            TranscriptSegment(text: "b first", t0: 0, t1: 1, source: .system,
                              confidence: 0.9, speaker: "Speaker 2", speakerID: bob.uuidString),
            TranscriptSegment(text: "hi", t0: 2, t1: 3, source: .system,
                              confidence: 0.9, speaker: "Alice", speakerID: alice.uuidString),
            TranscriptSegment(text: "me", t0: 4, t1: 5, source: .mic, confidence: 0.9)
        ], callID: call)

        let roster = try store.speakerProfiles(callID: call)
        XCTAssertEqual(roster.map(\.id), [bob, alice], "first-heard order, call-scoped")
        XCTAssertFalse(roster.contains { $0.id == stranger },
                       "voices from other calls must not appear")
    }
}
