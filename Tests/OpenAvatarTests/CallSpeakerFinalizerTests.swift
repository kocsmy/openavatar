import XCTest
@testable import OpenAvatar

/// The end-of-call speaker pass. Streaming diarization decides who is talking
/// from a 15-second window and gets it wrong by SPLITTING people — a four-way
/// call arriving as ten "speakers", some of them named after people who were
/// only mentioned. This pass re-clusters the finished recording and is the
/// thing that has to collapse those back down, so the collapse is pinned here.
final class FakeOfflineDiarizerBackend: OfflineDiarizerBackend, @unchecked Sendable {
    var turns: [SpeakerTurn] = []
    var error: Error?
    private(set) var requestedMaxSpeakers: Int?

    func diarize(fileURL: URL, maxSpeakers: Int?) async throws -> [SpeakerTurn] {
        requestedMaxSpeakers = maxSpeakers
        if let error { throw error }
        return turns
    }
}

final class CallSpeakerFinalizerTests: XCTestCase {

    private func turn(_ id: String, _ start: TimeInterval, _ end: TimeInterval,
                      value: Float = 0.1) -> SpeakerTurn {
        SpeakerTurn(backendSpeakerID: id,
                    embedding: [Float](repeating: value, count: 256),
                    start: start, end: end)
    }

    private func segment(_ t0: TimeInterval, _ t1: TimeInterval,
                         speaker: String? = nil, speakerID: String? = nil) -> TranscriptSegment {
        TranscriptSegment(text: "x", t0: t0, t1: t1, source: .system,
                          confidence: 0.9, speaker: speaker, speakerID: speakerID)
    }

    private func provisional(_ store: ContextStore, ordinal: Int, value: Float = 0.9) throws -> UUID {
        let now = Date()
        let profile = SpeakerProfile(id: UUID(), name: nil, ordinal: ordinal,
                                     embedding: [Float](repeating: value, count: 256),
                                     sampleCount: 1, createdAt: now, updatedAt: now)
        try store.insertSpeakerProfile(profile)
        return profile.id
    }

    // MARK: The regression this whole pass exists for

    /// Six fragments of two people collapse to two voices, and the strays are
    /// deleted rather than left to be enrolled into the next call.
    func testOverSplitCallCollapsesToTheVoicesActuallyPresent() async throws {
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Google Meet")

        // What streaming left behind: six unnamed profiles across the call.
        var strays: [UUID] = []
        for ordinal in 1...6 { strays.append(try provisional(store, ordinal: ordinal)) }
        let segments = (0..<6).map { i in
            segment(Double(i) * 20, Double(i) * 20 + 18,
                    speaker: "Speaker \(i + 1)", speakerID: strays[i].uuidString)
        }
        try store.insert(segments, callID: callID)

        // What the recording actually contains: two people alternating.
        let backend = FakeOfflineDiarizerBackend()
        backend.turns = (0..<6).map { i in
            turn(i.isMultiple(of: 2) ? "A" : "B", Double(i) * 20, Double(i) * 20 + 18)
        }
        let finalizer = CallSpeakerFinalizer(store: store, backend: backend)
        let outcome = await finalizer.finalize(
            callID: callID, audioURL: URL(fileURLWithPath: "/tmp/x.wav"), maxSpeakers: 3)

        XCTAssertEqual(outcome.voices, 2)
        XCTAssertEqual(outcome.removed, 6, "every provisional fingerprint should be swept")

        let voices = try store.speakerProfiles(callID: callID)
        XCTAssertEqual(voices.count, 2)
        XCTAssertEqual(try store.allSpeakerProfiles().count, 2,
                       "strays must not survive to be enrolled into the next call")

        // Numbering restarts per call — never "Speaker 31" on a two-way call.
        let labels = Set((try store.segments(callID: callID)).compactMap(\.speaker))
        XCTAssertEqual(labels, ["Speaker 1", "Speaker 2"])
    }

    /// The calendar roster reaches the clusterer as a ceiling on how many
    /// people it may find.
    func testRosterCeilingIsForwardedToTheBackend() async throws {
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Zoom")
        try store.insert([segment(0, 30)], callID: callID)
        let backend = FakeOfflineDiarizerBackend()
        backend.turns = [turn("A", 0, 30)]
        let finalizer = CallSpeakerFinalizer(store: store, backend: backend)

        _ = await finalizer.finalize(callID: callID,
                                     audioURL: URL(fileURLWithPath: "/tmp/x.wav"),
                                     maxSpeakers: 5)
        XCTAssertEqual(backend.requestedMaxSpeakers, 5)
    }

    /// A failed pass must cost nothing: the call keeps the labels it had.
    func testBackendFailureLeavesTheTranscriptAlone() async throws {
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Zoom")
        let stray = try provisional(store, ordinal: 1)
        try store.insert([segment(0, 30, speaker: "Speaker 1", speakerID: stray.uuidString)],
                         callID: callID)

        let backend = FakeOfflineDiarizerBackend()
        backend.error = AppError.integration("models unavailable")
        let finalizer = CallSpeakerFinalizer(store: store, backend: backend)
        let outcome = await finalizer.finalize(
            callID: callID, audioURL: URL(fileURLWithPath: "/tmp/x.wav"), maxSpeakers: nil)

        XCTAssertEqual(outcome, CallSpeakerFinalizer.Outcome())
        XCTAssertEqual(try store.segments(callID: callID).first?.speaker, "Speaker 1")
        XCTAssertEqual(try store.allSpeakerProfiles().count, 1)
    }

    /// A voice that barely spoke is shown but never remembered — thin
    /// centroids are what made matching unreliable in the first place.
    func testBriefVoiceNeverEarnsAFingerprint() async throws {
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Zoom")
        try store.insert([segment(0, 60), segment(61, 63)], callID: callID)

        let backend = FakeOfflineDiarizerBackend()
        backend.turns = [turn("A", 0, 60), turn("B", 61, 63)]   // B: 2 seconds
        let finalizer = CallSpeakerFinalizer(store: store, backend: backend)
        _ = await finalizer.finalize(callID: callID,
                                     audioURL: URL(fileURLWithPath: "/tmp/x.wav"),
                                     maxSpeakers: nil)

        XCTAssertEqual(try store.allSpeakerProfiles().count, 1)
        let brief = try store.segments(callID: callID).first { $0.t0 == 61 }
        XCTAssertNil(brief?.speakerID, "an unattributable span reads as Others")
    }

    /// A stored NAMED voice is recognized by centroid and keeps its name.
    func testNamedVoiceIsRecognizedByItsFingerprint() async throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let alice = SpeakerProfile(id: UUID(), name: "Alice", ordinal: 1,
                                   embedding: [Float](repeating: 0.1, count: 256),
                                   sampleCount: 20, createdAt: now, updatedAt: now)
        try store.insertSpeakerProfile(alice)
        let callID = try store.startCall(app: "Zoom")
        try store.insert([segment(0, 40)], callID: callID)

        let backend = FakeOfflineDiarizerBackend()
        backend.turns = [turn("A", 0, 40, value: 0.1)]
        let finalizer = CallSpeakerFinalizer(store: store, backend: backend)
        _ = await finalizer.finalize(callID: callID,
                                     audioURL: URL(fileURLWithPath: "/tmp/x.wav"),
                                     maxSpeakers: nil)

        let seg = try XCTUnwrap(store.segments(callID: callID).first)
        XCTAssertEqual(seg.speakerID, alice.id.uuidString)
        XCTAssertEqual(seg.speaker, "Alice")
        XCTAssertEqual(try store.allSpeakerProfiles().count, 1)
    }

    // MARK: Pure helpers

    func testClustersAreDurationWeighted() {
        let clusters = CallSpeakerFinalizer.clusters(from: [
            turn("A", 0, 10), turn("B", 10, 12), turn("A", 12, 20)
        ])
        XCTAssertEqual(clusters.map(\.backendSpeakerID), ["A", "B"])   // first-heard order
        XCTAssertEqual(clusters[0].speech, 18)
        XCTAssertEqual(clusters[1].speech, 2)
    }

    func testPlacementTakesTheMajorityOverlap() {
        let a = segment(0, 9), b = segment(11, 19)
        let placed = CallSpeakerFinalizer.place(
            turns: [turn("A", 0, 10), turn("B", 10, 20)], segments: [a, b])
        XCTAssertEqual(placed[a.id], "A")
        XCTAssertEqual(placed[b.id], "B")
    }

    func testOnlyNamedProfilesAreMatchCandidates() {
        let now = Date()
        let embedding = [Float](repeating: 0.1, count: 256)
        let unnamed = SpeakerProfile(id: UUID(), name: nil, ordinal: 1, embedding: embedding,
                                     sampleCount: 3, createdAt: now, updatedAt: now)
        XCTAssertNil(CallSpeakerFinalizer.nearestNamed(to: embedding, among: [unnamed]),
                     "matching last week's Speaker 12 spreads its mistakes")

        let named = SpeakerProfile(id: UUID(), name: "Bea", ordinal: 2, embedding: embedding,
                                   sampleCount: 30, createdAt: now, updatedAt: now)
        XCTAssertEqual(CallSpeakerFinalizer.nearestNamed(to: embedding, among: [named]), named.id)

        // A different voice stays unmatched rather than borrowing her name.
        let far = [Float](repeating: 0, count: 256).enumerated().map { i, _ in
            i.isMultiple(of: 2) ? Float(1) : Float(-1)
        }
        XCTAssertNil(CallSpeakerFinalizer.nearestNamed(to: far, among: [named]))
    }

    func testLiveConsensusNeedsNearUnanimity() {
        let now = Date()
        let bea = SpeakerProfile(id: UUID(), name: "Bea", ordinal: 1,
                                 embedding: [Float](repeating: 0.1, count: 256),
                                 sampleCount: 9, createdAt: now, updatedAt: now)
        let strong = (0..<10).map { i in
            segment(Double(i), Double(i) + 1,
                    speakerID: i < 9 ? bea.id.uuidString : UUID().uuidString)
        }
        XCTAssertEqual(CallSpeakerFinalizer.liveConsensus(strong, stored: [bea]), bea.id)

        let split = (0..<10).map { i in
            segment(Double(i), Double(i) + 1,
                    speakerID: i < 5 ? bea.id.uuidString : UUID().uuidString)
        }
        XCTAssertNil(CallSpeakerFinalizer.liveConsensus(split, stored: [bea]))
    }
}
