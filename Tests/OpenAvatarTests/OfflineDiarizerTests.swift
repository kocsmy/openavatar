import XCTest
import SpeakerKit
@testable import OpenAvatar

/// The SpeakerKit adapter's pure edges: WAV bytes in, our SpeakerTurns out.
/// The model pipeline itself is not run here (CoreML downloads in CI); these
/// pin the two conversions wrapping it.
final class OfflineDiarizerTests: XCTestCase {

    /// Call recordings are WAVEncoder's canonical 16 kHz mono 16-bit WAV; the
    /// loader must hand SpeakerKit the exact samples, header dropped,
    /// normalized the same way the transcriber normalizes.
    func testWavLoaderRoundTripsEncodedPCM() throws {
        let ints: [Int16] = [0, 16_384, -16_384, 32_767, -32_768]
        var pcm = Data()
        for value in ints {
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openavatar-wav-\(UUID().uuidString).wav")
        try WAVEncoder.wavData(fromPCM: pcm).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try SpeakerKitOfflineDiarizerBackend.samples(fromWAV: url)
        XCTAssertEqual(samples.count, ints.count)
        XCTAssertEqual(samples, ints.map { Float($0) / 32768.0 })
    }

    func testEmptyRecordingYieldsNoSamples() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openavatar-wav-\(UUID().uuidString).wav")
        try WAVEncoder.wavData(fromPCM: Data()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try SpeakerKitOfflineDiarizerBackend.samples(fromWAV: url), [])
    }

    /// Each turn carries its speaker's cluster centroid; spans SpeakerKit
    /// could not pin on one voice (overlap, no match) are dropped and read
    /// as "Others" downstream.
    func testDiarizationResultMapsToTurns() {
        let centroid: [Float] = [0.1, 0.2, 0.3]
        let result = DiarizationResult(
            speakerCount: 2,
            totalFrames: 100,
            frameRate: 10,
            segments: [
                SpeakerSegment(speaker: .speakerId(0), startTime: 0, endTime: 4, frameRate: 10),
                SpeakerSegment(speaker: .noMatch, startTime: 4, endTime: 5, frameRate: 10),
                SpeakerSegment(speaker: .speakerId(1), startTime: 5, endTime: 9, frameRate: 10)
            ],
            speakerCentroidEmbeddings: [0: centroid])

        let turns = SpeakerKitOfflineDiarizerBackend.turns(from: result)
        XCTAssertEqual(turns.map(\.backendSpeakerID), ["0", "1"])
        XCTAssertEqual(turns[0].embedding, centroid)
        XCTAssertEqual(turns[1].embedding, [], "a missing centroid is empty, never invented")
        XCTAssertEqual(turns[0].start, 0)
        XCTAssertEqual(turns[0].end, 4)
    }
}
