import XCTest
@testable import OpenAvatar

/// The pure parts of the Parakeet engine — PCM conversion and mode plumbing.
/// (Model loading/inference needs the ~600 MB CoreML download and real
/// hardware, so it isn't exercised in CI.)
final class ParakeetTranscriberTests: XCTestCase {

    func testFloatSamplesConversion() {
        var pcm = Data()
        for v in [Int16(0), 16384, -16384, 32767, -32768] {
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let samples = ParakeetTranscriber.floatSamples(fromPCM: pcm)
        XCTAssertEqual(samples.count, 5)
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(samples[2], -0.5, accuracy: 0.001)
        XCTAssertEqual(samples[3], 1.0, accuracy: 0.001)
        XCTAssertEqual(samples[4], -1.0, accuracy: 0.001)
    }

    func testFloatSamplesEmptyAndOddData() {
        XCTAssertTrue(ParakeetTranscriber.floatSamples(fromPCM: Data()).isEmpty)
        // A trailing odd byte is ignored, never crashes.
        XCTAssertEqual(ParakeetTranscriber.floatSamples(fromPCM: Data([0x00, 0x40, 0x7F])).count, 1)
    }

    func testTranscriptionModeRoundTrip() {
        // Settings persist the raw value; every case must survive the trip
        // (a renamed case would silently reset users to the default engine).
        for mode in TranscriptionMode.allCases {
            XCTAssertEqual(TranscriptionMode(rawValue: mode.rawValue), mode)
        }
        XCTAssertEqual(TranscriptionMode(rawValue: "parakeet"), .parakeet)
    }

    // MARK: Whisper model-quality resolution

    /// Regression: "Re-check" ran setup with a hard default of .base, silently
    /// downgrading a user who had picked (and downloaded) a bigger model.
    func testWhisperRecheckKeepsTheActiveModel() {
        let largePath = "/models/ggml-large-v3-turbo.bin"
        XCTAssertEqual(WhisperSetupService.resolveModel(requested: nil, currentPath: largePath),
                       .largeTurbo)
        // An explicit pick always wins.
        XCTAssertEqual(WhisperSetupService.resolveModel(requested: .small, currentPath: largePath),
                       .small)
        // True first run (no model configured yet) starts at base.
        XCTAssertEqual(WhisperSetupService.resolveModel(requested: nil, currentPath: ""),
                       .base)
    }
}
