import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// The result of diarizing one utterance: a stable voice-fingerprint id plus
/// the label to show (a user-assigned name, or "Speaker N").
struct DiarizedSpeaker: Sendable, Equatable {
    let id: UUID
    let label: String
}

/// On-device per-voice diarization for the system-audio ("Others") channel.
///
/// Approach — no ML model, no network: derive a compact acoustic embedding
/// per utterance from its audio (log-mel spectral envelope + median pitch),
/// then match it against persistent voice fingerprints by cosine similarity.
/// A matched voice reuses its stored profile (and its user-assigned name);
/// an unseen voice creates a new profile. Because profiles are persisted, a
/// name given to a voice carries across every past and future call. The mic
/// channel is always "You" and never diarized.
///
/// This is a genuine attempt, not production-grade diarization: it separates a
/// handful of clearly-distinct voices well, but can merge similar voices or
/// split one speaker across very different acoustic conditions.
actor SpeakerDiarizer {
    /// Cosine similarity above which an utterance joins an existing speaker.
    /// Deliberately fairly strict: merging two *different* voices into one is the
    /// worse, unfixable-in-place error, whereas over-splitting one voice into a
    /// few "Speaker N" entries is easily corrected with Merge. Higher = stricter.
    private let joinThreshold: Float = 0.84
    /// Utterances quieter/shorter than these are left as "Others".
    private let minSamples = 16_000 / 4        // 0.25 s at 16 kHz
    private let minRMS: Float = 0.006

    private let store: ContextStore
    /// Working set of known voice fingerprints, loaded from the store.
    private var profiles: [SpeakerProfile] = []
    private var loaded = false
    private let extractor = EmbeddingExtractor()

    init(store: ContextStore = .shared) {
        self.store = store
    }

    /// Load persisted fingerprints so voices are recognized across calls.
    /// Called at the start of each call; cheap and idempotent.
    func reset() {
        profiles = (try? store.allSpeakerProfiles()) ?? []
        loaded = true
    }

    /// Assigns a speaker to one transcript segment using the slice of `chunk`
    /// that covers the segment's time range. Returns the matched/created voice
    /// fingerprint and its display label, or nil to fall back to "Others".
    func label(for segment: TranscriptSegment, in chunk: AudioChunk) -> DiarizedSpeaker? {
        guard segment.source == .system else { return nil }
        if !loaded { reset() }
        let samples = pcmSlice(chunk: chunk, t0: segment.t0, t1: segment.t1)
        guard samples.count >= minSamples else { return nil }
        guard let embedding = extractor.embedding(samples), rms(samples) >= minRMS else { return nil }

        // Nearest known voice by cosine similarity.
        var bestIndex = -1
        var bestSim: Float = -1
        for (i, profile) in profiles.enumerated() {
            let sim = cosine(embedding, profile.embedding)
            if sim > bestSim { bestSim = sim; bestIndex = i }
        }

        if bestIndex >= 0 && bestSim >= joinThreshold {
            // Update the running-average centroid and persist it.
            var p = profiles[bestIndex]
            let n = Float(p.sampleCount)
            if p.embedding.count == embedding.count {
                for k in 0..<p.embedding.count {
                    p.embedding[k] = (p.embedding[k] * n + embedding[k]) / (n + 1)
                }
            }
            p.sampleCount += 1
            p.updatedAt = Date()
            profiles[bestIndex] = p
            try? store.updateSpeakerEmbedding(id: p.id, embedding: p.embedding, sampleCount: p.sampleCount)
            return DiarizedSpeaker(id: p.id, label: p.displayLabel)
        }

        // Unseen voice → new persistent fingerprint.
        let ordinal = (try? store.nextSpeakerOrdinal()) ?? (profiles.count + 1)
        let now = Date()
        let profile = SpeakerProfile(id: UUID(), name: nil, ordinal: ordinal,
                                     embedding: embedding, sampleCount: 1,
                                     createdAt: now, updatedAt: now)
        profiles.append(profile)
        try? store.insertSpeakerProfile(profile)
        return DiarizedSpeaker(id: profile.id, label: profile.displayLabel)
    }

    var speakerCount: Int { profiles.count }

    // MARK: Helpers

    /// Extracts the [t0, t1] window (call-relative seconds) from a chunk's PCM.
    private func pcmSlice(chunk: AudioChunk, t0: TimeInterval, t1: TimeInterval) -> [Float] {
        let rate = Double(WAVEncoder.sampleRate)
        let total = chunk.pcm.count / MemoryLayout<Int16>.size
        let chunkDuration = Double(total) / rate
        // Offsets within the chunk (segment times are chunk.t0-relative).
        let startSec = max(0, min(chunkDuration, t0 - chunk.t0))
        let endSec = max(startSec, min(chunkDuration, t1 - chunk.t0))
        let startSample = Int(startSec * rate)
        let endSample = min(total, Int(endSec * rate))
        guard endSample > startSample else { return [] }

        return chunk.pcm.withUnsafeBytes { raw -> [Float] in
            let ints = raw.bindMemory(to: Int16.self)
            var out = [Float](repeating: 0, count: endSample - startSample)
            for i in startSample..<endSample {
                out[i - startSample] = Float(ints[i]) / 32768.0
            }
            return out
        }
    }

    private func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var sum: Float = 0
        for v in x { sum += v * v }
        return (sum / Float(x.count)).squareRoot()
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }
}

/// Turns a mono 16 kHz float slice into a fixed-length speaker embedding:
/// an L2-normalized log-mel spectral envelope with the median pitch appended
/// (pitch is one of the strongest cheap voice discriminators).
final class EmbeddingExtractor {
    private let fftLength = 4096
    private let melBands = 24

#if canImport(Accelerate)
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup?
    private let melFilters: [[Float]]   // melBands × (fftLength/2)

    init() {
        log2n = vDSP_Length(log2(Float(fftLength)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        melFilters = EmbeddingExtractor.buildMelFilterbank(
            bins: fftLength / 2, bands: melBands, sampleRate: Float(WAVEncoder.sampleRate))
    }

    deinit { if let fftSetup { vDSP_destroy_fftsetup(fftSetup) } }

    /// Returns melBands + 1 (pitch) floats, L2-normalized, or nil.
    func embedding(_ samples: [Float]) -> [Float]? {
        guard let fftSetup, samples.count >= fftLength / 2 else { return nil }
        let half = fftLength / 2

        // Average magnitude spectrum across consecutive (Hann-windowed) blocks.
        var meanMag = [Float](repeating: 0, count: half)
        var blocks = 0
        var window = [Float](repeating: 0, count: fftLength)
        vDSP_hann_window(&window, vDSP_Length(fftLength), Int32(vDSP_HANN_NORM))

        var pos = 0
        while pos + fftLength <= samples.count {
            var frame = [Float](repeating: 0, count: fftLength)
            for i in 0..<fftLength { frame[i] = samples[pos + i] * window[i] }
            let mag = magnitudeSpectrum(frame, fftSetup: fftSetup)
            for i in 0..<half { meanMag[i] += mag[i] }
            blocks += 1
            pos += fftLength   // non-overlapping blocks keep it cheap
        }
        // If the slice was shorter than a couple of blocks, use one padded block.
        if blocks == 0 {
            var frame = [Float](repeating: 0, count: fftLength)
            for i in 0..<min(fftLength, samples.count) {
                frame[i] = samples[i] * window[i]
            }
            meanMag = magnitudeSpectrum(frame, fftSetup: fftSetup)
            blocks = 1
        }
        for i in 0..<half { meanMag[i] /= Float(blocks) }

        // Mel bands → log → L2 normalize.
        var envelope = [Float](repeating: 0, count: melBands)
        for b in 0..<melBands {
            var acc: Float = 0
            let filter = melFilters[b]
            for i in 0..<half { acc += meanMag[i] * filter[i] }
            envelope[b] = log(acc + 1e-6)
        }
        normalize(&envelope)

        // Pitch feature (median F0), mapped to ~[0,1] and appended with weight.
        let f0 = medianPitch(samples)
        let pitchFeature = f0 > 0 ? Float((log(Double(f0)) - log(70.0)) / (log(350.0) - log(70.0))) : 0.5
        var embedding = envelope
        // Pitch is one of the strongest cheap discriminators between voices, so
        // weight it heavily relative to the spectral envelope.
        embedding.append(pitchFeature * 3.0)
        normalize(&embedding)
        return embedding
    }

    private func magnitudeSpectrum(_ frame: [Float], fftSetup: FFTSetup) -> [Float] {
        let half = fftLength / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                frame.withUnsafeBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        for i in 0..<half { mags[i] = mags[i].squareRoot() }
        return mags
    }

    private static func buildMelFilterbank(bins: Int, bands: Int, sampleRate: Float) -> [[Float]] {
        func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }
        let lowMel = hzToMel(80)
        let highMel = hzToMel(min(8000, sampleRate / 2))
        let points = (0...(bands + 1)).map { i -> Float in
            melToHz(lowMel + (highMel - lowMel) * Float(i) / Float(bands + 1))
        }
        let binHz = (sampleRate / 2) / Float(bins)
        var filters = [[Float]](repeating: [Float](repeating: 0, count: bins), count: bands)
        for b in 0..<bands {
            let f0 = points[b], f1 = points[b + 1], f2 = points[b + 2]
            for i in 0..<bins {
                let hz = Float(i) * binHz
                if hz >= f0 && hz <= f1 {
                    filters[b][i] = (hz - f0) / max(1, f1 - f0)
                } else if hz > f1 && hz <= f2 {
                    filters[b][i] = (f2 - hz) / max(1, f2 - f1)
                }
            }
        }
        return filters
    }

    /// Median fundamental frequency via normalized autocorrelation (70–350 Hz).
    private func medianPitch(_ samples: [Float]) -> Float {
        let rate = Float(WAVEncoder.sampleRate)
        let minLag = Int(rate / 350), maxLag = Int(rate / 70)
        guard samples.count > maxLag * 2 else { return 0 }
        var f0s: [Float] = []
        let frame = Int(rate * 0.04)   // 40 ms frames
        var pos = 0
        while pos + frame + maxLag < samples.count {
            var bestLag = 0
            var bestCorr: Float = 0
            var energy: Float = 0
            for i in 0..<frame { energy += samples[pos + i] * samples[pos + i] }
            if energy > 0.01 {
                for lag in minLag...maxLag {
                    var corr: Float = 0
                    for i in 0..<frame { corr += samples[pos + i] * samples[pos + i + lag] }
                    if corr > bestCorr { bestCorr = corr; bestLag = lag }
                }
                if bestLag > 0 { f0s.append(rate / Float(bestLag)) }
            }
            pos += frame
        }
        guard !f0s.isEmpty else { return 0 }
        f0s.sort()
        return f0s[f0s.count / 2]
    }

    private func normalize(_ v: inout [Float]) {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        if norm > 0 { for i in 0..<v.count { v[i] /= norm } }
    }
#else
    init() {}
    func embedding(_ samples: [Float]) -> [Float]? { nil }
#endif
}
