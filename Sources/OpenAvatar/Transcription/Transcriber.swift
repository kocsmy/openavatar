import Foundation

/// Spec §4.2 — the transcription abstraction. Two implementations:
/// local whisper.cpp and cloud (OpenAI-compatible) STT.
protocol Transcriber: Sendable {
    func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSegment]
}

/// Encodes mono 16 kHz 16-bit PCM into a WAV container (whisper.cpp and the
/// OpenAI audio endpoint both accept WAV).
enum WAVEncoder {
    static let sampleRate: UInt32 = 16_000
    static let bitsPerSample: UInt16 = 16
    static let channels: UInt16 = 1

    static func wavData(fromPCM pcm: Data) -> Data {
        var data = Data()
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)

        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: 36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16))            // fmt chunk size
        data.append(littleEndian: UInt16(1))             // PCM
        data.append(littleEndian: channels)
        data.append(littleEndian: sampleRate)
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: dataSize)
        data.append(pcm)
        return data
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
