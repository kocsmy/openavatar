import XCTest
@testable import OpenAvatar

/// The Qwen3-ASR engine's install layout and mode plumbing. The bridge
/// process itself needs Python + Apple Silicon and is exercised manually.
final class QwenTranscriberTests: XCTestCase {

    @MainActor func testRuntimePathsLiveInAppSupport() {
        XCTAssertTrue(QwenSetupService.runtimeDir.path.contains("OpenAvatar"))
        XCTAssertTrue(QwenSetupService.bridgeScriptURL.path
            .hasSuffix("qwen3-asr-mlx-runtime/scripts/qwen3-asr-mlx-bridge"))
    }

    func testQwenModePersistsAndDisplays() {
        XCTAssertEqual(TranscriptionMode(rawValue: "qwen"), .qwen)
        XCTAssertTrue(TranscriptionMode.qwen.displayName.contains("52"))
    }
}
