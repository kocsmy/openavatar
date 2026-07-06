import Foundation

/// Local, private, offline transcription via whisper.cpp (spec §4.2).
///
/// v1 integration strategy: shell out to the `whisper-cli` binary
/// (`brew install whisper-cpp`) with JSON output, rather than linking
/// libwhisper directly. This keeps the build dependency-free; the binary and
/// model paths are configurable in Settings. Metal acceleration comes for
/// free from the Homebrew build.
struct WhisperLocalTranscriber: Transcriber {
    let cliPath: String
    let modelPath: String

    func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSegment] {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            throw AppError.notConfigured("whisper-cli not found at \(cliPath). Install with `brew install whisper-cpp` or set the path in Settings → Transcription.")
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw AppError.notConfigured("Whisper model not found at \(modelPath). Download one in Settings → Transcription.")
        }

        let workDir = AppPaths.scratch
        let base = "chunk-\(UUID().uuidString)"
        let wavURL = workDir.appendingPathComponent("\(base).wav")
        let outBase = workDir.appendingPathComponent(base).path
        let jsonURL = workDir.appendingPathComponent("\(base).json")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: jsonURL)
        }

        try WAVEncoder.wavData(fromPCM: chunk.pcm).write(to: wavURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "-m", modelPath,
            "-f", wavURL.path,
            "--output-json", "--output-file", outBase,
            "--no-prints", "--language", "en"
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AppError.audio("whisper-cli failed: \(err.prefix(300))")
        }

        let json = try JSONValue.parse(try Data(contentsOf: jsonURL))
        return Self.parseSegments(json, chunk: chunk)
    }

    /// whisper.cpp JSON output: { "transcription": [ { "offsets": {"from": ms, "to": ms}, "text": "..." } ] }
    static func parseSegments(_ json: JSONValue, chunk: AudioChunk) -> [TranscriptSegment] {
        (json["transcription"]?.arrayValue ?? []).compactMap { entry in
            let text = (entry["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isNoise(text) else { return nil }
            let fromMs = entry["offsets"]?["from"]?.numberValue ?? 0
            let toMs = entry["offsets"]?["to"]?.numberValue ?? 0
            return TranscriptSegment(
                text: text,
                t0: chunk.t0 + fromMs / 1000.0,
                t1: chunk.t0 + toMs / 1000.0,
                source: chunk.source,
                confidence: 0.9) // whisper-cli JSON has no per-segment confidence; use fixed prior
        }
    }

    /// Filters whisper hallucination artifacts on silence.
    static func isNoise(_ text: String) -> Bool {
        let noise = ["[BLANK_AUDIO]", "[Music]", "[music]", "(silence)", "[silence]", "."]
        return noise.contains(text) || text.allSatisfy { !$0.isLetter }
    }
}
