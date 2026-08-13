import XCTest
@testable import OpenAvatar

/// Per-voice diarization: the backend finds acoustic speaker turns, transcript
/// segments take the majority-overlap speaker, and stored fingerprints are
/// enrolled so names persist across calls. The backend is scripted here —
/// FluidAudio's real pipeline would download CoreML models in CI.
final class FakeDiarizerBackend: DiarizerBackend, @unchecked Sendable {
    var ready = true
    /// Turns returned per diarize() call, consumed in order.
    var script: [[SpeakerTurn]] = []
    var enrolledIDs: [String] = []
    var finals: [String: [Float]] = [:]

    var isReady: Bool { ready }
    func prepare() async throws {}
    func enroll(_ known: [(id: String, name: String?, embedding: [Float])]) {
        enrolledIDs = known.map(\.id)
    }
    func diarize(_ samples: [Float], at time: TimeInterval) throws -> [SpeakerTurn] {
        script.isEmpty ? [] : script.removeFirst()
    }
    func finalEmbeddings() -> [String: [Float]] { finals }
}

final class DiarizationTests: XCTestCase {

    private func chunk(t0: TimeInterval = 0, seconds: Double = 15,
                       source: AudioSource = .system) -> AudioChunk {
        AudioChunk(pcm: Data(count: Int(seconds * 16_000) * 2),
                   source: source, t0: t0, t1: t0 + seconds)
    }

    private func segment(_ t0: TimeInterval, _ t1: TimeInterval,
                         source: AudioSource = .system) -> TranscriptSegment {
        TranscriptSegment(text: "x", t0: t0, t1: t1, source: source, confidence: 0.9)
    }

    private func turn(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerTurn {
        SpeakerTurn(backendSpeakerID: id,
                    embedding: [Float](repeating: 0.1, count: 256),
                    start: start, end: end)
    }

    private func makeDiarizer(store: ContextStore, backend: FakeDiarizerBackend) -> SpeakerDiarizer {
        SpeakerDiarizer(store: store, backendFactory: { backend })
    }

    func testMicChannelNeverDiarized() async throws {
        let store = try ContextStore(inMemory: true)
        let diarizer = makeDiarizer(store: store, backend: FakeDiarizerBackend())
        let hit = await diarizer.label(for: segment(0, 1, source: .mic))
        XCTAssertNil(hit)   // → falls back to "You"
    }

    func testSpeakerLabelPrefersDiarizedSpeaker() {
        var seg = segment(0, 1)
        XCTAssertEqual(seg.speakerLabel, "Others")
        seg.speaker = "Speaker 3"
        XCTAssertEqual(seg.speakerLabel, "Speaker 3")
    }

    /// Two acoustic voices inside one chunk → two persistent profiles, and
    /// each transcript span gets the voice that did most of its talking.
    func testTwoVoicesInOneChunkGetDistinctSpeakers() async throws {
        let store = try ContextStore(inMemory: true)
        let backend = FakeDiarizerBackend()
        backend.script = [[turn("A", 0, 7), turn("B", 7, 15)]]
        let diarizer = makeDiarizer(store: store, backend: backend)
        await diarizer.beginCall()

        await diarizer.ingest(chunk: chunk())
        let first = await diarizer.label(for: segment(1, 6))
        let second = await diarizer.label(for: segment(8, 14))

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.id, second?.id)
        XCTAssertEqual(Set([first?.label, second?.label]), ["Speaker 1", "Speaker 2"])
    }

    /// Unnamed fingerprints from earlier calls are NOT enrolled. Seeding the
    /// backend with every voice it had ever heard gave dozens of weak
    /// centroids the chance to claim a stranger's speech — that is how people
    /// who were never on a call ended up in its transcript. Only voices the
    /// user (or the roster) actually named are worth matching; the rest are
    /// regrouped from scratch by the end-of-call pass.
    func testOnlyNamedProfilesAreEnrolled() async throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let named = SpeakerProfile(id: UUID(), name: "Alice", ordinal: 1,
                                   embedding: [Float](repeating: 0.2, count: 256),
                                   sampleCount: 12, createdAt: now, updatedAt: now)
        let stray = SpeakerProfile(id: UUID(), name: nil, ordinal: 2,
                                   embedding: [Float](repeating: 0.4, count: 256),
                                   sampleCount: 1, createdAt: now, updatedAt: now)
        try store.insertSpeakerProfile(named)
        try store.insertSpeakerProfile(stray)

        let backend = FakeDiarizerBackend()
        backend.script = [[]]
        let diarizer = makeDiarizer(store: store, backend: backend)
        await diarizer.beginCall()
        await diarizer.ingest(chunk: chunk())

        XCTAssertEqual(backend.enrolledIDs, [named.id.uuidString])
    }

    /// Live "Speaker N" numbering restarts each call. The stored ordinal is a
    /// database detail — surfacing it made a four-person meeting read
    /// "Speaker 31, Speaker 52, …".
    func testSpeakerNumberingIsScopedToTheCall() async throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        for ordinal in 1...30 {
            try store.insertSpeakerProfile(SpeakerProfile(
                id: UUID(), name: nil, ordinal: ordinal,
                embedding: [Float](repeating: 0.5, count: 256),
                sampleCount: 1, createdAt: now, updatedAt: now))
        }
        let backend = FakeDiarizerBackend()
        backend.script = [[turn("A", 0, 7), turn("B", 7, 15)]]
        let diarizer = makeDiarizer(store: store, backend: backend)
        await diarizer.beginCall()
        await diarizer.ingest(chunk: chunk())

        let first = await diarizer.label(for: segment(1, 6))
        let second = await diarizer.label(for: segment(8, 14))
        XCTAssertEqual([first?.label, second?.label], ["Speaker 1", "Speaker 2"])
    }

    /// The same backend voice across many chunks stays ONE profile.
    func testSameVoiceAcrossChunksStaysOneSpeaker() async throws {
        let store = try ContextStore(inMemory: true)
        let backend = FakeDiarizerBackend()
        backend.script = [
            [turn("A", 0, 14)],
            [turn("A", 15, 29)],
            [turn("A", 30, 44)]
        ]
        let diarizer = makeDiarizer(store: store, backend: backend)
        await diarizer.beginCall()

        var ids = Set<UUID>()
        for start in [0.0, 15.0, 30.0] {
            await diarizer.ingest(chunk: chunk(t0: start))
            if let hit = await diarizer.label(for: segment(start + 1, start + 13)) {
                ids.insert(hit.id)
            }
        }
        XCTAssertEqual(ids.count, 1)
        let count = await diarizer.speakerCount
        XCTAssertEqual(count, 1)
    }

    /// A transcript span with no overlapping turn (below the backend's
    /// minimum) glues to the nearest turn instead of minting anything.
    func testGapSegmentFallsToNearestTurnAndNeverMints() async throws {
        let store = try ContextStore(inMemory: true)
        let backend = FakeDiarizerBackend()
        backend.script = [[turn("A", 0, 5)]]
        let diarizer = makeDiarizer(store: store, backend: backend)
        await diarizer.beginCall()

        await diarizer.ingest(chunk: chunk())
        let near = await diarizer.label(for: segment(5.2, 6.0))   // 0.2s after A stops
        XCTAssertNotNil(near, "A near-miss should glue to the adjacent turn")
        let far = await diarizer.label(for: segment(9, 10))       // 4s away
        XCTAssertNil(far, "Nothing nearby → Others, never a stray profile")
        let count = await diarizer.speakerCount
        XCTAssertEqual(count, 1)
    }

    /// A named stored fingerprint is enrolled into the backend; when the
    /// backend assigns its id, the name carries — across calls, no new profile.
    func testNamePersistsAcrossCallsViaEnrollment() async throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let alice = SpeakerProfile(id: UUID(), name: "Alice", ordinal: 1,
                                   embedding: [Float](repeating: 0.2, count: 256),
                                   sampleCount: 12, createdAt: now, updatedAt: now)
        try store.insertSpeakerProfile(alice)

        let backend = FakeDiarizerBackend()
        backend.script = [[turn(alice.id.uuidString, 0, 10)]]
        let diarizer = makeDiarizer(store: store, backend: backend)
        await diarizer.beginCall()

        await diarizer.ingest(chunk: chunk())
        XCTAssertEqual(backend.enrolledIDs, [alice.id.uuidString])
        let hit = await diarizer.label(for: segment(1, 9))
        XCTAssertEqual(hit?.id, alice.id)
        XCTAssertEqual(hit?.label, "Alice")
        let count = await diarizer.speakerCount
        XCTAssertEqual(count, 1, "An enrolled voice must not mint a duplicate profile")
    }

    /// Legacy spectral fingerprints (25-dim) are never enrolled — wrong
    /// vector space — but they stay in the store untouched.
    func testLegacyProfilesAreNotEnrolled() async throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let legacy = SpeakerProfile(id: UUID(), name: "Old Bob", ordinal: 1,
                                    embedding: [Float](repeating: 0.3, count: 25),
                                    sampleCount: 40, createdAt: now, updatedAt: now)
        try store.insertSpeakerProfile(legacy)

        let backend = FakeDiarizerBackend()
        backend.script = [[]]
        let diarizer = makeDiarizer(store: store, backend: backend)
        await diarizer.beginCall()
        await diarizer.ingest(chunk: chunk())

        XCTAssertTrue(backend.enrolledIDs.isEmpty)
        XCTAssertEqual(try store.allSpeakerProfiles().count, 1)
    }

    /// endCall writes the backend's evolved centroid back to the store.
    func testEndCallPersistsEvolvedEmbeddings() async throws {
        let store = try ContextStore(inMemory: true)
        let backend = FakeDiarizerBackend()
        backend.script = [[turn("A", 0, 10)]]
        let diarizer = makeDiarizer(store: store, backend: backend)
        await diarizer.beginCall()
        await diarizer.ingest(chunk: chunk())
        _ = await diarizer.label(for: segment(1, 9))

        let evolved = [Float](repeating: 0.5, count: 256)
        backend.finals = ["A": evolved]
        await diarizer.endCall()

        let stored = try XCTUnwrap(store.allSpeakerProfiles().first)
        XCTAssertEqual(stored.embedding, evolved)
        XCTAssertGreaterThan(stored.sampleCount, 1)
    }

    /// A named voice absorbs a call's audio only once the end-of-call pass has
    /// confirmed the person was there. Skipping that check is how one wrong
    /// match becomes many: the centroid drifts toward whoever was really
    /// speaking, so the next call matches them even more confidently.
    func testUnconfirmedNamedVoiceKeepsItsFingerprint() async throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let original = [Float](repeating: 0.2, count: 256)
        let claire = SpeakerProfile(id: UUID(), name: "Claire", ordinal: 1, embedding: original,
                                    sampleCount: 12, createdAt: now, updatedAt: now)
        try store.insertSpeakerProfile(claire)

        let backend = FakeDiarizerBackend()
        backend.script = [[turn(claire.id.uuidString, 0, 10)]]
        let diarizer = makeDiarizer(store: store, backend: backend)
        await diarizer.beginCall()
        await diarizer.ingest(chunk: chunk())
        _ = await diarizer.label(for: segment(1, 9))

        let drifted = [Float](repeating: 0.9, count: 256)
        backend.finals = [claire.id.uuidString: drifted]

        await diarizer.endCall()
        XCTAssertEqual(try store.allSpeakerProfiles().first?.embedding, original,
                       "an unconfirmed match must not rewrite somebody's voice")

        await diarizer.endCall(confirmed: [claire.id])
        XCTAssertEqual(try store.allSpeakerProfiles().first?.embedding, drifted)
    }

    /// The roster narrows live enrollment too. Every named voice in the
    /// database otherwise arrives as a permanent centroid competing for each
    /// turn, and on a two-person call one voice gets scattered across them.
    func testRosterNarrowsEnrollment() async throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let joao = SpeakerProfile(id: UUID(), name: "Joao", ordinal: 1,
                                  embedding: [Float](repeating: 0.2, count: 256),
                                  sampleCount: 12, createdAt: now, updatedAt: now)
        let claire = SpeakerProfile(id: UUID(), name: "Claire", ordinal: 2,
                                    embedding: [Float](repeating: 0.4, count: 256),
                                    sampleCount: 12, createdAt: now, updatedAt: now)
        try store.insertSpeakerProfile(joao)
        try store.insertSpeakerProfile(claire)

        let backend = FakeDiarizerBackend()
        backend.script = [[]]
        let diarizer = makeDiarizer(store: store, backend: backend)
        await diarizer.beginCall()
        await diarizer.setRoster(["Joao Ferreira"])
        await diarizer.ingest(chunk: chunk())

        XCTAssertEqual(backend.enrolledIDs, [joao.id.uuidString])
    }
}

/// The pure timeline join: transcript spans → majority-overlap speaker.
final class SpeakerTimelineTests: XCTestCase {

    func testMajorityOverlapWins() {
        var t = SpeakerTimeline()
        let a = UUID(), b = UUID()
        t.add(speakerID: a, start: 0, end: 4)
        t.add(speakerID: b, start: 4, end: 10)
        XCTAssertEqual(t.speaker(overlapping: 1, 9), b)   // 5s of B vs 3s of A
        XCTAssertEqual(t.speaker(overlapping: 0, 4.5), a)
    }

    func testNearestWithinToleranceWhenNoOverlap() {
        var t = SpeakerTimeline()
        let a = UUID()
        t.add(speakerID: a, start: 0, end: 3)
        XCTAssertEqual(t.speaker(overlapping: 3.5, 4.0), a)
        XCTAssertNil(t.speaker(overlapping: 10, 11))
    }

    func testTrimDropsOldTurnsOnly() {
        var t = SpeakerTimeline()
        let a = UUID(), b = UUID()
        t.add(speakerID: a, start: 0, end: 5)
        t.add(speakerID: b, start: 100, end: 110)
        t.trim(before: 50)
        XCTAssertEqual(t.turns.map(\.speakerID), [b])
    }
}
