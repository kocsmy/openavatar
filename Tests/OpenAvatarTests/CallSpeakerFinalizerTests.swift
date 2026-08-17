import XCTest
@testable import OpenAvatar

/// The end-of-call speaker pass. Streaming diarization decides who is talking
/// from a 15-second window and gets it wrong by SPLITTING people — a four-way
/// call arriving as ten "speakers". This pass re-clusters the finished
/// recording and collapses those back down. Just as load-bearing is what it
/// must NOT do: recognize a cluster acoustically against voices stored from
/// earlier calls — that recognition is how a two-person call once listed six
/// people who were nowhere near it, and it is gone.
final class FakeOfflineDiarizerBackend: OfflineDiarizerBackend, @unchecked Sendable {
    var turns: [SpeakerTurn] = []
    var error: Error?
    private(set) var requestedMaxSpeakers: Int?
    private(set) var diarizeCalls = 0

    func diarize(fileURL: URL, maxSpeakers: Int?) async throws -> [SpeakerTurn] {
        diarizeCalls += 1
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

    // MARK: Collapsing over-splits

    /// Six fragments of two people collapse to two voices, and the strays are
    /// deleted rather than left to clutter the database.
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
                       "strays must not survive the call")

        // Numbering restarts per call — never "Speaker 31" on a two-way call.
        let labels = Set((try store.segments(callID: callID)).compactMap(\.speaker))
        XCTAssertEqual(labels, ["Speaker 1", "Speaker 2"])
    }

    /// The calendar roster reaches the clusterer as a cap on how many people
    /// it may find.
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

    /// No recording (audio buffering failed, or diarization came up empty)
    /// on a multi-party call → nothing changes.
    func testMissingAudioLeavesTheTranscriptAlone() async throws {
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Zoom")
        try store.insert([segment(0, 30, speaker: "Speaker 1")], callID: callID)

        let backend = FakeOfflineDiarizerBackend()
        let finalizer = CallSpeakerFinalizer(store: store, backend: backend)
        let outcome = await finalizer.finalize(callID: callID, audioURL: nil, maxSpeakers: nil)

        XCTAssertEqual(outcome, CallSpeakerFinalizer.Outcome())
        XCTAssertEqual(backend.diarizeCalls, 0)
        XCTAssertEqual(try store.segments(callID: callID).first?.speaker, "Speaker 1")
    }

    /// A voice that barely spoke is shown but never remembered — thin
    /// centroids are noise, not people.
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

    // MARK: No cross-call recognition — the core invariant

    /// THE invariant this design rests on: a voice stored and named on an
    /// earlier call is never matched acoustically, even when the fingerprints
    /// are identical. Far-end call audio cannot support that matching — with
    /// enough named voices on file, something is always "close enough" to a
    /// stranger, which is how a two-person call once listed six absent people.
    func testStoredVoicesAreNeverRecognizedAcoustically() async throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let shared = [Float](repeating: 0.1, count: 256)
        for name in ["Conrad", "Vasilis", "Paul", "Tiago", "Ben", "Claire"] {
            try store.insertSpeakerProfile(SpeakerProfile(
                id: UUID(), name: name, ordinal: 1, embedding: shared,
                sampleCount: 30, createdAt: now, updatedAt: now))
        }
        let callID = try store.startCall(app: "Google Meet")
        try store.insert([segment(0, 40)], callID: callID)

        let backend = FakeOfflineDiarizerBackend()
        backend.turns = [turn("A", 0, 40, value: 0.1)]   // identical to all six
        let finalizer = CallSpeakerFinalizer(store: store, backend: backend)
        let outcome = await finalizer.finalize(callID: callID,
                                               audioURL: URL(fileURLWithPath: "/tmp/x.wav"),
                                               maxSpeakers: nil)

        XCTAssertEqual(outcome.voices, 1)
        let seg = try XCTUnwrap(store.segments(callID: callID).first)
        XCTAssertEqual(seg.speaker, "Speaker 1",
                       "a perfect acoustic match must still not borrow a stored name")
    }

    /// A name typed DURING the call (mid-call rename, 1:1 prefill) is the one
    /// kind of name the pass keeps — it came from a human, not from matching.
    func testMidCallRenameSurvivesThePass() async throws {
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Zoom")
        let voice = try provisional(store, ordinal: 1)
        try store.renameSpeaker(id: voice, to: "Bea")
        let segments = (0..<5).map { i in
            segment(Double(i) * 10, Double(i) * 10 + 9,
                    speaker: "Bea", speakerID: voice.uuidString)
        }
        try store.insert(segments, callID: callID)

        let backend = FakeOfflineDiarizerBackend()
        backend.turns = (0..<5).map { i in turn("A", Double(i) * 10, Double(i) * 10 + 9) }
        let finalizer = CallSpeakerFinalizer(store: store, backend: backend)
        _ = await finalizer.finalize(callID: callID,
                                     audioURL: URL(fileURLWithPath: "/tmp/x.wav"),
                                     maxSpeakers: nil)

        let seg = try XCTUnwrap(store.segments(callID: callID).first)
        XCTAssertEqual(seg.speakerID, voice.uuidString)
        XCTAssertEqual(seg.speaker, "Bea")
        XCTAssertEqual(try store.allSpeakerProfiles().count, 1, "no duplicate voice minted")
    }

    // MARK: The 1:1 shortcut

    /// A meeting with exactly one other invitee has a deterministic answer:
    /// the whole system channel IS that person. No clustering, no audio, no
    /// inference — and stray live voices are swept.
    func testOneOnOneCallBelongsToTheInvitee() async throws {
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Google Meet")
        var strays: [UUID] = []
        for ordinal in 1...3 { strays.append(try provisional(store, ordinal: ordinal)) }
        let segments = (0..<3).map { i in
            segment(Double(i) * 20, Double(i) * 20 + 18,
                    speaker: "Speaker \(i + 1)", speakerID: strays[i].uuidString)
        }
        try store.insert(segments, callID: callID)

        let backend = FakeOfflineDiarizerBackend()
        let finalizer = CallSpeakerFinalizer(store: store, backend: backend)
        let outcome = await finalizer.finalize(callID: callID, audioURL: nil,
                                               maxSpeakers: 2, roster: ["João Ferreira"])

        XCTAssertEqual(outcome.voices, 1)
        XCTAssertEqual(backend.diarizeCalls, 0, "a 1:1 call needs no clustering at all")
        let stored = try store.segments(callID: callID)
        XCTAssertEqual(Set(stored.compactMap(\.speaker)), ["João Ferreira"])
        XCTAssertEqual(try store.allSpeakerProfiles().count, 1)
        XCTAssertEqual(try store.allSpeakerProfiles().first?.name, "João Ferreira")
    }

    /// When the live prefill already named this call's voice after the one
    /// invitee, the shortcut keeps that profile instead of minting another.
    func testOneOnOneKeepsTheLiveNamedProfile() async throws {
        let store = try ContextStore(inMemory: true)
        let callID = try store.startCall(app: "Zoom")
        let voice = try provisional(store, ordinal: 1)
        try store.renameSpeaker(id: voice, to: "João Ferreira")
        try store.insert([segment(0, 30, speaker: "João Ferreira", speakerID: voice.uuidString),
                          segment(31, 60)], callID: callID)

        let finalizer = CallSpeakerFinalizer(store: store,
                                             backend: FakeOfflineDiarizerBackend())
        let outcome = await finalizer.finalize(callID: callID, audioURL: nil,
                                               maxSpeakers: 2, roster: ["João Ferreira"])

        XCTAssertEqual(outcome.voices, 1)
        XCTAssertEqual(try store.allSpeakerProfiles().count, 1)
        let stored = try store.segments(callID: callID)
        XCTAssertEqual(stored.compactMap(\.speakerID), [voice.uuidString, voice.uuidString],
                       "both spans, including the unattributed one, belong to the invitee")
    }

    /// A profile named like the invitee on an EARLIER call is not reused —
    /// voices are per-call, even when the names coincide.
    func testOneOnOneNeverReusesAnotherCallsProfile() async throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let old = SpeakerProfile(id: UUID(), name: "João Ferreira", ordinal: 1,
                                 embedding: [Float](repeating: 0.2, count: 256),
                                 sampleCount: 40, createdAt: now, updatedAt: now)
        try store.insertSpeakerProfile(old)
        // Reference the old profile from an old call so it survives sweeping.
        let oldCall = try store.startCall(app: "Zoom")
        try store.insert([segment(0, 10, speaker: "João Ferreira",
                                  speakerID: old.id.uuidString)], callID: oldCall)

        let callID = try store.startCall(app: "Zoom")
        try store.insert([segment(0, 30)], callID: callID)

        let finalizer = CallSpeakerFinalizer(store: store,
                                             backend: FakeOfflineDiarizerBackend())
        _ = await finalizer.finalize(callID: callID, audioURL: nil,
                                     maxSpeakers: 2, roster: ["João Ferreira"])

        let seg = try XCTUnwrap(store.segments(callID: callID).first)
        XCTAssertNotEqual(seg.speakerID, old.id.uuidString,
                          "same name, different call — a fresh voice, not a link")
        XCTAssertEqual(seg.speaker, "João Ferreira")
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
