import Foundation

/// One voice on one call. `name` comes from the calendar (the 1:1 shortcut),
/// a mid-call rename, or the post-call LLM pass — never from acoustic
/// matching, and never from another call: profiles are per-call records, not
/// identities the app recognizes people by. `ordinal` is a friendly fallback
/// label ("Speaker 3") until a name arrives. `embedding` is kept for
/// reference (the cluster centroid that produced the voice) but nothing
/// matches against it.
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
