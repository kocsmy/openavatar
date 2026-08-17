import XCTest
@testable import OpenAvatar

/// Live per-voice diarization: the backend finds acoustic speaker turns and
/// transcript segments take the majority-overlap speaker. Voices are per-call
/// — the backend starts every call empty and stored fingerprints are never
/// fed to it. The backend is scripted here; FluidAudio's real pipeline would
/// download CoreML models in CI.
final class FakeDiarizerBackend: DiarizerBackend, @unchecked Sendable {
    var ready = true
    /// Turns returned per diarize() call, consumed in order.
    var script: [[SpeakerTurn]] = []

    var isReady: Bool { ready }
    func prepare() async throws {}
    func diarize(_ samples: [Float], at time: TimeInterval) throws -> [SpeakerTurn] {
        script.isEmpty ? [] : script.removeFirst()
    }
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

    /// Two acoustic voices inside one chunk → two per-call profiles, and each
    /// transcript span gets the voice that did most of its talking.
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

    /// The recognition that kept putting absent people on calls is gone: a
    /// voice named on an earlier call stays out of this one. The backend
    /// starts empty, so a new call's voices are always fresh "Speaker N"
    /// profiles, never somebody from the database.
    func testStoredNamesNeverAppearLive() async throws {
        let store = try ContextStore(inMemory: true)
        let now = Date()
        let alice = SpeakerProfile(id: UUID(), name: "Alice", ordinal: 1,
                                   embedding: [Float](repeating: 0.2, count: 256),
                                   sampleCount: 12, createdAt: now, updatedAt: now)
        try store.insertSpeakerProfile(alice)

        let backend = FakeDiarizerBackend()
        backend.script = [[turn("X", 0, 10)]]
        let diarizer = makeDiarizer(store: store, backend: backend)
        await diarizer.beginCall()
        await diarizer.ingest(chunk: chunk())

        let hit = try XCTUnwrap(await diarizer.label(for: segment(1, 9)))
        XCTAssertNotEqual(hit.id, alice.id)
        XCTAssertEqual(hit.label, "Speaker 1",
                       "a stored name may only reach a call through a human or the roster")
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

    /// A mid-call rename shows up on the very next utterance after reset().
    func testRenameCarriesToLaterUtterancesInTheSameCall() async throws {
        let store = try ContextStore(inMemory: true)
        let backend = FakeDiarizerBackend()
        backend.script = [[turn("A", 0, 10)], [turn("A", 15, 25)]]
        let diarizer = makeDiarizer(store: store, backend: backend)
        await diarizer.beginCall()

        await diarizer.ingest(chunk: chunk())
        let before = try XCTUnwrap(await diarizer.label(for: segment(1, 9)))
        XCTAssertEqual(before.label, "Speaker 1")

        try store.renameSpeaker(id: before.id, to: "João")
        await diarizer.reset()

        await diarizer.ingest(chunk: chunk(t0: 15))
        let after = await diarizer.label(for: segment(16, 24))
        XCTAssertEqual(after?.id, before.id)
        XCTAssertEqual(after?.label, "João")
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
