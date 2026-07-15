import XCTest
@testable import OpenAvatar

/// The persistent voice fingerprint store: renaming a voice must relabel its
/// whole transcript history and survive as a reusable profile.
final class SpeakerProfileStoreTests: XCTestCase {

    func testRenameRelabelsPastSegments() throws {
        let store = try ContextStore(inMemory: true)
        let profileID = UUID()
        let now = Date()
        try store.insertSpeakerProfile(SpeakerProfile(
            id: profileID, name: nil, ordinal: 1, embedding: [0.1, 0.2, 0.3],
            sampleCount: 1, createdAt: now, updatedAt: now))

        let callID = try store.startCall(app: "Zoom")
        let seg = TranscriptSegment(text: "hello there", t0: 0, t1: 1, source: .system,
                                    confidence: 0.9, speaker: "Speaker 1",
                                    speakerID: profileID.uuidString)
        try store.insert([seg], callID: callID)

        try store.renameSpeaker(id: profileID, to: "Alice")

        let reloaded = try store.segments(callID: callID)
        XCTAssertEqual(reloaded.first?.speaker, "Alice")
        XCTAssertEqual(reloaded.first?.speakerID, profileID.uuidString)

        // Clearing the name reverts the row to the friendly ordinal label.
        try store.renameSpeaker(id: profileID, to: nil)
        XCTAssertEqual(try store.segments(callID: callID).first?.speaker, "Speaker 1")
    }

    func testProfileRoundTripPreservesEmbedding() throws {
        let store = try ContextStore(inMemory: true)
        let embedding: [Float] = [0.5, -0.25, 0.125, 1.0]
        let id = UUID()
        let now = Date()
        try store.insertSpeakerProfile(SpeakerProfile(
            id: id, name: "Bob", ordinal: 2, embedding: embedding,
            sampleCount: 4, createdAt: now, updatedAt: now))

        let loaded = try XCTUnwrap(store.allSpeakerProfiles().first { $0.id == id })
        XCTAssertEqual(loaded.name, "Bob")
        XCTAssertEqual(loaded.ordinal, 2)
        XCTAssertEqual(loaded.sampleCount, 4)
        XCTAssertEqual(loaded.embedding, embedding)
    }

    func testMergeFoldsSourceIntoTarget() throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let alice = UUID(), stray = UUID()
        try store.insertSpeakerProfile(SpeakerProfile(
            id: alice, name: "Alice", ordinal: 1, embedding: [1, 0, 0],
            sampleCount: 3, createdAt: now, updatedAt: now))
        try store.insertSpeakerProfile(SpeakerProfile(
            id: stray, name: nil, ordinal: 2, embedding: [0, 1, 0],
            sampleCount: 1, createdAt: now, updatedAt: now))

        let callID = try store.startCall(app: nil)
        try store.insert([
            TranscriptSegment(text: "hi", t0: 0, t1: 1, source: .system, confidence: 0.9,
                              speaker: "Alice", speakerID: alice.uuidString),
            TranscriptSegment(text: "yo", t0: 1, t1: 2, source: .system, confidence: 0.9,
                              speaker: "Speaker 2", speakerID: stray.uuidString)
        ], callID: callID)

        try store.mergeSpeaker(stray, into: alice)

        let profiles = try store.allSpeakerProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, alice)
        XCTAssertEqual(profiles.first?.sampleCount, 4)  // 3 + 1 utterances combined

        let segs = try store.segments(callID: callID)
        XCTAssertTrue(segs.allSatisfy { $0.speakerID == alice.uuidString })
        XCTAssertTrue(segs.allSatisfy { $0.speaker == "Alice" })
    }

    func testMergeAdoptsSourceNameWhenTargetUnnamed() throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let target = UUID(), named = UUID()
        try store.insertSpeakerProfile(SpeakerProfile(
            id: target, name: nil, ordinal: 1, embedding: [1, 0],
            sampleCount: 1, createdAt: now, updatedAt: now))
        try store.insertSpeakerProfile(SpeakerProfile(
            id: named, name: "Bob", ordinal: 2, embedding: [0, 1],
            sampleCount: 1, createdAt: now, updatedAt: now))

        try store.mergeSpeaker(named, into: target)

        let profiles = try store.allSpeakerProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.name, "Bob")   // target adopts the source's name
    }

    func testNextOrdinalIncrements() throws {
        let store = try ContextStore(inMemory: true)
        XCTAssertEqual(try store.nextSpeakerOrdinal(), 1)
        let now = Date()
        try store.insertSpeakerProfile(SpeakerProfile(
            id: UUID(), name: nil, ordinal: 1, embedding: [1], sampleCount: 1,
            createdAt: now, updatedAt: now))
        XCTAssertEqual(try store.nextSpeakerOrdinal(), 2)
    }
}
