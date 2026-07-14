import Foundation
import Combine

/// One-click local-transcription setup: finds (or installs via Homebrew) the
/// whisper-cli binary and downloads the base.en model. Used from onboarding
/// and Settings → Transcription so users never hand-edit paths.
@MainActor
final class WhisperSetupService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case installingCLI          // brew install whisper-cpp
        case downloadingModel
        case done(String)           // human summary
        case failed(String)
    }

    @Published var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .checking, .installingCLI, .downloadingModel: return true
        default: return false
        }
    }

    static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!

    private static let cliCandidates = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/homebrew/opt/whisper-cpp/bin/whisper-cli"
    ]

    private static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    // MARK: Detection

    static func findWhisperCLI(settingsPath: String) -> String? {
        var candidates = [settingsPath]
        candidates.append(contentsOf: cliCandidates)
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: the user's login shell PATH.
        if let found = try? shell("command -v whisper-cli"),
           !found.isEmpty, FileManager.default.isExecutableFile(atPath: found) {
            return found
        }
        return nil
    }

    static func modelExists(at path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return size > 50_000_000 // guards against truncated downloads
    }

    /// Is local transcription fully ready with current settings?
    static func isReady(settings: SettingsStore) -> Bool {
        findWhisperCLI(settingsPath: settings.whisperCLIPath) != nil
            && modelExists(at: settings.whisperModelPath)
    }

    // MARK: Setup

    func run(settings: SettingsStore) async {
        phase = .checking

        // 1. whisper-cli binary.
        var cliPath = Self.findWhisperCLI(settingsPath: settings.whisperCLIPath)
        if cliPath == nil {
            guard let brew = Self.brewCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                phase = .failed("whisper-cli not found and Homebrew isn't installed. Install Homebrew (brew.sh), then retry — or set the path manually below.")
                return
            }
            phase = .installingCLI
            do {
                try await Self.shellAsync("\(brew) install whisper-cpp", timeout: 600)
            } catch {
                phase = .failed("Homebrew install failed: \(error.localizedDescription)")
                return
            }
            cliPath = Self.findWhisperCLI(settingsPath: settings.whisperCLIPath)
            guard cliPath != nil else {
                phase = .failed("Installed whisper-cpp but couldn't locate whisper-cli afterwards — set the path manually below.")
                return
            }
        }
        settings.whisperCLIPath = cliPath!

        // 2. Model file (~150 MB, one-time).
        let modelPath = AppPaths.models.appendingPathComponent("ggml-base.en.bin").path
        if !Self.modelExists(at: modelPath) {
            phase = .downloadingModel
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: Self.modelURL)
                guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false else {
                    phase = .failed("Model download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)). Retry, or download ggml-base.en.bin manually from huggingface.co/ggerganov/whisper.cpp.")
                    return
                }
                let destination = URL(fileURLWithPath: modelPath)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tempURL, to: destination)
            } catch {
                phase = .failed("Model download failed: \(error.localizedDescription)")
                return
            }
        }
        settings.whisperModelPath = modelPath
        settings.transcriptionMode = .local

        phase = .done("Local transcription ready — whisper-cli at \(cliPath!), base.en model installed.")
    }

    // MARK: Shell helpers

    private static func shell(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

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
