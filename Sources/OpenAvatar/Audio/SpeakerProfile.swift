import Foundation

/// A persistent voice fingerprint — one per distinct voice ever heard on the
/// system ("Others") channel. `name` is user-assigned and, once set, carries
/// the speaker's identity across every past and future call: the diarizer
/// matches new utterances against these stored fingerprints, so the same voice
/// gets the same name automatically next time. `ordinal` is a friendly
/// fallback label ("Speaker 3") until the user names the voice.
struct SpeakerProfile: Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String?
    var ordinal: Int
    /// L2-normalized acoustic embedding (running-average centroid).
    var embedding: [Float]
    var sampleCount: Int
    var createdAt: Date
    var updatedAt: Date

    /// What the transcript shows for this voice.
    var displayLabel: String { name ?? "Speaker \(ordinal)" }

    var isNamed: Bool { !(name ?? "").isEmpty }
}

extension SpeakerProfile {
    /// Little-endian Float32 blob for SQLite storage.
    static func encode(_ embedding: [Float]) -> Data {
        var copy = embedding
        return copy.withUnsafeMutableBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        // copyBytes is alignment-safe; the SQLite blob isn't guaranteed 4-byte aligned.
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0, count: count * MemoryLayout<Float>.size) }
        return floats
    }
}
