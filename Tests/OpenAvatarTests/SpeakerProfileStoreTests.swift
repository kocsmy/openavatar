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
