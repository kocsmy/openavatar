import Foundation

/// Local transcription via Alibaba's Qwen3-ASR-1.7B on Apple's MLX framework
/// — currently the most accurate open model that runs on-device (52 languages
/// and dialects, including Hungarian; ~3.4 GB of weights).
///
/// There is no Swift runtime for it, so we run the qwen3-asr-mlx-runtime
/// bridge: a long-lived Python subprocess (installed one-time by
/// QwenSetupService, models cached under ~/.audio-models) speaking
/// newline-delimited JSON over stdin/stdout. The model loads once and stays
/// resident; each chunk is written as a temp WAV and transcribed in place.
actor Qwen3Transcriber: Transcriber {
    static let shared = Qwen3Transcriber()

    static let model = "Qwen/Qwen3-ASR-1.7B"

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var ready = false

    var isReady: Bool { ready && process?.isRunning == true }

    /// Launch the bridge and wait for the model to load. First run installs
    /// the Python environment and downloads the weights — that can take many
    /// minutes and needs the network; afterwards it's offline and loads in
    /// seconds.
    func prepare() async throws {
        if isReady { return }
        try launchIfNeeded()
        let response = try await request(["type": "start"], timeoutSeconds: 3600)
        guard response["type"] as? String == "ready" else {
            throw AppError.notConfigured(
                "Qwen3-ASR bridge did not become ready: \(response["message"] as? String ?? "unknown error")")
        }
        ready = true
    }

    func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSegment] {
        try await prepare()

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-\(UUID().uuidString).wav")
        try WAVEncoder.wavData(fromPCM: chunk.pcm).write(to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let response = try await request(["type": "transcribe", "audio": wavURL.path],
                                         timeoutSeconds: 120)
        if response["type"] as? String == "error" {
            throw AppError.notConfigured(
                "Qwen3-ASR failed: \(response["message"] as? String ?? "unknown error")")
        }
        guard let text = (response["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty, !WhisperLocalTranscriber.isNoise(text) else { return [] }
        return [TranscriptSegment(text: text, t0: chunk.t0, t1: chunk.t1,
                                  source: chunk.source, confidence: 0.9)]
    }

    /// Shut the bridge down (frees ~4 GB of memory). Restarts on next use.
    func shutdown() {
        if let stdinPipe, process?.isRunning == true {
            try? stdinPipe.fileHandleForWriting.write(contentsOf:
                Data("{\"type\":\"stop\"}\n".utf8))
        }
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutHandle = nil
        stdoutBuffer = Data()
        ready = false
    }

    // MARK: Bridge process

    private func launchIfNeeded() throws {
        if process?.isRunning == true { return }
        ready = false
        stdoutBuffer = Data()

        let script = QwenSetupService.bridgeScriptURL
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw AppError.notConfigured(
                "Qwen3-ASR runtime is not installed — run the setup in Settings → Transcription.")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, Self.model]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr   // installer + model-load progress; discarded
        stderr.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        try p.run()
        process = p
        stdinPipe = stdin
        stdoutHandle = stdout.fileHandleForReading
    }

    /// One request → one JSON-line response (the bridge is strictly serial).
    private func request(_ message: [String: Any],
                         timeoutSeconds: TimeInterval) async throws -> [String: Any] {
        guard let stdinPipe, let stdoutHandle else {
            throw AppError.notConfigured("Qwen3-ASR bridge is not running")
        }
        let data = try JSONSerialization.data(withJSONObject: message)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let line = nextLine() {
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    return obj
                }
                continue   // non-JSON noise on stdout; keep reading
            }
            guard process?.isRunning == true else {
                shutdown()
                throw AppError.notConfigured(
                    "Qwen3-ASR bridge exited — its first start installs Python packages and downloads the model, which needs a network connection. Retry from Settings → Transcription.")
            }
            // Blocking read off the actor's thread; chunks arrive quickly.
            let handle = stdoutHandle
            let chunk = await Task.detached { handle.availableData }.value
            if chunk.isEmpty {
                try await Task.sleep(nanoseconds: 100_000_000)
            } else {
                stdoutBuffer.append(chunk)
            }
        }
        throw AppError.notConfigured("Qwen3-ASR timed out")
    }

    private func nextLine() -> Data? {
        guard let newline = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newline)
        stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
        return line
    }
}
