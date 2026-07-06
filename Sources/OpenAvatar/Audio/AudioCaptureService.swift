import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Spec §4.1 — captures two streams (mic + system/call audio), mixes each to
/// mono 16 kHz 16-bit PCM, and emits ~15 s chunks with overlap for streaming
/// transcription. Never records unless explicitly started; the menu-bar icon
/// always reflects `isRunning` (hard trust requirement, spec §5.1).
final class AudioCaptureService: @unchecked Sendable {
    typealias ChunkHandler = @Sendable (AudioChunk) -> Void

    private(set) var isRunning = false
    private let onChunk: ChunkHandler

    /// Chunk length before hand-off to transcription; overlap keeps words that
    /// straddle a boundary.
    private let chunkSeconds: TimeInterval = 15
    private let overlapSeconds: TimeInterval = 2

    private var startDate = Date()
    private var micAccumulator = PCMAccumulator(source: .mic)
    private var systemAccumulator = PCMAccumulator(source: .system)
    private let queue = DispatchQueue(label: "com.openavatar.audio")

#if canImport(AVFoundation)
    private let engine = AVAudioEngine()
    private var systemTap: SystemAudioTap?
#endif

    init(onChunk: @escaping ChunkHandler) {
        self.onChunk = onChunk
    }

    // MARK: Lifecycle

    func start() throws {
        guard !isRunning else { return }
        startDate = Date()
        micAccumulator.reset()
        systemAccumulator.reset()
#if canImport(AVFoundation)
        try startMic()
        do {
            let tap = SystemAudioTap { [weak self] samples, sampleRate in
                guard let self else { return }
                self.queue.async {
                    self.ingest(samples: samples, sampleRate: sampleRate, into: &self.systemAccumulator)
                }
            }
            try tap.start()
            systemTap = tap
        } catch {
            // Mic-only capture still works (e.g. permission not yet granted);
            // callers surface the degraded state in the UI.
            NSLog("System audio tap unavailable: %@", Redactor.redact(error.localizedDescription))
        }
#endif
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
#if canImport(AVFoundation)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        systemTap?.stop()
        systemTap = nil
#endif
        // Flush whatever is buffered so trailing speech isn't lost.
        queue.sync {
            flush(&micAccumulator, force: true)
            flush(&systemAccumulator, force: true)
        }
        isRunning = false
    }

#if canImport(AVFoundation)
    private func startMic() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = Self.downmixToFloatMono(buffer)
            self.queue.async {
                self.ingest(samples: samples, sampleRate: inputFormat.sampleRate, into: &self.micAccumulator)
            }
        }
        engine.prepare()
        try engine.start()
    }

    static func downmixToFloatMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channelCount {
            let ptr = channels[c]
            for i in 0..<frames { mono[i] += ptr[i] }
        }
        if channelCount > 1 {
            let scale = 1.0 / Float(channelCount)
            for i in 0..<frames { mono[i] *= scale }
        }
        return mono
    }
#endif

    // MARK: Resample + chunk

    private func ingest(samples: [Float], sampleRate: Double, into accumulator: inout PCMAccumulator) {
        accumulator.append(samples: samples, sourceRate: sampleRate)
        flush(&accumulator, force: false)
    }

    private func flush(_ accumulator: inout PCMAccumulator, force: Bool) {
        let targetSamples = Int(chunkSeconds * Double(WAVEncoder.sampleRate))
        let minimumSamples = force ? Int(0.5 * Double(WAVEncoder.sampleRate)) : targetSamples
        guard accumulator.sampleCount >= minimumSamples else { return }

        let elapsed = Date().timeIntervalSince(startDate)
        let duration = Double(accumulator.sampleCount) / Double(WAVEncoder.sampleRate)
        let chunk = AudioChunk(pcm: accumulator.takePCM(keepOverlapSeconds: force ? 0 : overlapSeconds),
                               source: accumulator.source,
                               t0: max(0, elapsed - duration),
                               t1: elapsed)
        onChunk(chunk)
    }
}

/// Accumulates float samples at an arbitrary rate and converts to 16 kHz
/// 16-bit mono PCM using linear-interpolation resampling.
struct PCMAccumulator {
    let source: AudioSource
    private var resampled: [Int16] = []
    private var pendingInput: [Float] = []
    private var lastRate: Double = 48_000

    init(source: AudioSource) {
        self.source = source
    }

    var sampleCount: Int { resampled.count }

    mutating func reset() {
        resampled.removeAll()
        pendingInput.removeAll()
    }

    mutating func append(samples: [Float], sourceRate: Double) {
        lastRate = sourceRate
        pendingInput.append(contentsOf: samples)
        let ratio = sourceRate / Double(WAVEncoder.sampleRate)
        guard ratio > 0 else { return }
        let outCount = Int(Double(pendingInput.count) / ratio)
        guard outCount > 0 else { return }
        var out = [Int16](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Double(i) * ratio
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let a = pendingInput[idx]
            let b = idx + 1 < pendingInput.count ? pendingInput[idx + 1] : a
            let sample = a + (b - a) * frac
            out[i] = Int16(max(-1, min(1, sample)) * 32767)
        }
        let consumed = Int(Double(outCount) * ratio)
        pendingInput.removeFirst(min(consumed, pendingInput.count))
        resampled.append(contentsOf: out)
    }

    /// Returns accumulated PCM as Data, keeping the tail for overlap.
    mutating func takePCM(keepOverlapSeconds: TimeInterval) -> Data {
        let data = resampled.withUnsafeBufferPointer { Data(buffer: $0) }
        let keep = Int(keepOverlapSeconds * Double(WAVEncoder.sampleRate))
        if keep > 0 && resampled.count > keep {
            resampled = Array(resampled.suffix(keep))
        } else {
            resampled.removeAll()
        }
        return data
    }
}
