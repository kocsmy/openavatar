import Foundation

/// One-click setup for the Qwen3-ASR MLX bridge: installs `uv` (via
/// Homebrew) if needed and downloads the bridge runtime into Application
/// Support. The Python environment and the ~3.4 GB model weights are pulled
/// by the bridge itself on its first start ("Download & prepare" in the
/// engine setup section) and cached under ~/.audio-models.
@MainActor
final class QwenSetupService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case installingUV
        case downloadingRuntime
        case preparingModel     // bridge's first start: pip env + weights
        case done(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .installingUV, .downloadingRuntime, .preparingModel: return true
        default: return false
        }
    }

    // Paths and installedness checks are pure/filesystem-only and read from
    // the transcriber actor too — hence nonisolated despite the @MainActor class.

    /// Pinned bridge release so app updates don't silently change the runtime.
    nonisolated static let runtimeTarball =
        URL(string: "https://github.com/drguptavivek/qwen3-asr-mlx-runtime/archive/refs/heads/main.tar.gz")!

    nonisolated static var runtimeDir: URL {
        AppPaths.appSupport.appendingPathComponent("qwen3-asr-mlx-runtime", isDirectory: true)
    }

    nonisolated static var bridgeScriptURL: URL {
        runtimeDir.appendingPathComponent("scripts/qwen3-asr-mlx-bridge")
    }

    private nonisolated static let uvCandidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
    private nonisolated static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    nonisolated static var uvInstalled: Bool {
        uvCandidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The runtime is on disk and uv exists — the bridge can be started.
    /// (Model weights may still download on first start.)
    nonisolated static var runtimeInstalled: Bool {
        uvInstalled && FileManager.default.fileExists(atPath: bridgeScriptURL.path)
    }

    /// Install uv + the bridge runtime, then warm the model (env + weights).
    func run(settings: SettingsStore) async {
        // 1. uv (Python manager the bridge script uses).
        if !Self.uvInstalled {
            guard let brew = Self.brewCandidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0) }) else {
                phase = .failed("Homebrew isn't installed (needed for uv). Install it from brew.sh, then retry.")
                return
            }
            phase = .installingUV
            do {
                try await Self.shellAsync("\(brew) install uv", timeout: 600)
            } catch {
                phase = .failed("Installing uv failed: \(error.localizedDescription)")
                return
            }
        }

        // 2. The bridge runtime (small tarball; Python deps come later).
        if !FileManager.default.fileExists(atPath: Self.bridgeScriptURL.path) {
            phase = .downloadingRuntime
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: Self.runtimeTarball)
                guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false else {
                    phase = .failed("Runtime download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)). Retry in a moment.")
                    return
                }
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("qwen-runtime-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try await Self.shellAsync(
                    "tar -xzf '\(tempURL.path)' -C '\(staging.path)' --strip-components=1", timeout: 120)
                try? FileManager.default.removeItem(at: Self.runtimeDir)
                try FileManager.default.moveItem(at: staging, to: Self.runtimeDir)
                try await Self.shellAsync("chmod +x '\(Self.bridgeScriptURL.path)'", timeout: 30)
            } catch {
                phase = .failed("Runtime download failed: \(error.localizedDescription)")
                return
            }
        }

        // 3. First bridge start: Python env + model weights (~3.4 GB, one-time).
        phase = .preparingModel
        do {
            try await Qwen3Transcriber.shared.prepare()
        } catch {
            phase = .failed(Redactor.redact(error.localizedDescription))
            return
        }

        settings.transcriptionMode = .qwen
        phase = .done("Qwen3-ASR 1.7B is ready — model loaded, transcription runs on this Mac via MLX.")
    }

    // MARK: Shell helper

    private static func shellAsync(_ command: String, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-lc", command]
                    let errPipe = Pipe()
                    process.standardOutput = Pipe()
                    process.standardError = errPipe
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                         encoding: .utf8) ?? ""
                        continuation.resume(throwing: AppError.integration(String(err.suffix(300))))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
