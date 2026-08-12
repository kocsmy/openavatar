import Foundation

/// Holds the call's "Others" (system) audio on disk while the call runs, so
/// the end-of-call pass can re-diarize the WHOLE recording in one go.
///
/// Why this exists: diarizing 15-second chunks independently is what made one
/// person fragment into six "speakers" — each window clusters in isolation and
/// a two-second utterance produces an embedding too weak to match, so the
/// backend mints another id. Global clustering over the finished recording
/// can't make that mistake, but it needs the whole recording (see
/// OfflineDiarizer).
///
/// The file is a plain 16 kHz mono WAV in the temp directory. Samples are
/// written at their absolute call-clock offset, so the diarizer's timeline and
/// the transcript's timestamps share one clock and the join is exact — that
/// also makes the capture's ~2 s chunk overlap harmless, since the repeated
/// samples land back on top of themselves. Silence between chunks is a hole in
/// a sparse file, costing nothing.
///
/// It never leaves the machine and never outlives the call: `finish()` hands
/// over the URL, and `discard()` deletes it as soon as the pass is done.
actor CallAudioRecorder {
    /// ~3 hours at 32 kB/s. Past this the recording stops growing — a
    /// forgotten open session must not fill the disk. The call keeps its
    /// streaming labels instead.
    static let maxBytes = 3 * 3600 * Int(WAVEncoder.sampleRate) * 2

    /// A canonical WAV header is 44 bytes; PCM starts after it.
    private static let headerBytes = 44

    private var handle: FileHandle?
    private var url: URL?
    /// Highest byte offset (past the header) written so far — the header's
    /// declared data size at `finish()`.
    private var highWaterMark = 0

    /// Open a fresh recording for a call. Any previous one is discarded.
    func begin(callID: UUID) {
        discard()
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("openavatar-call-\(callID.uuidString).wav")
        // A header with a zero-length data chunk; the sizes are patched in
        // finish(), once we know how long the call actually ran.
        guard FileManager.default.createFile(
                path: target.path, contents: WAVEncoder.wavData(fromPCM: Data())),
              let opened = try? FileHandle(forWritingTo: target) else {
            NSLog("Call audio buffer unavailable — speakers will keep their live labels")
            return
        }
        handle = opened
        url = target
        highWaterMark = 0
    }

    /// Append one system-audio chunk at its position on the call clock.
    func append(_ chunk: AudioChunk) {
        guard let handle, chunk.source == .system, !chunk.pcm.isEmpty else { return }
        let offset = Int(chunk.t0 * Double(WAVEncoder.sampleRate)) * 2
        guard offset >= 0, offset + chunk.pcm.count <= Self.maxBytes else { return }
        do {
            try handle.seek(toOffset: UInt64(Self.headerBytes + offset))
            try handle.write(contentsOf: chunk.pcm)
            highWaterMark = max(highWaterMark, offset + chunk.pcm.count)
        } catch {
            // A failed write costs us diarization quality, never the call.
            NSLog("Call audio buffer write failed: %@", Redactor.redact(error.localizedDescription))
        }
    }

    /// Close the file and hand back a playable WAV, or nil when there's too
    /// little audio to be worth clustering.
    func finish() -> URL? {
        guard let handle, let url else { return nil }
        // Patch RIFF/data sizes now that the length is known.
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Self.header(dataSize: highWaterMark))
        try? handle.close()
        self.handle = nil
        // Under ~20 s of speech there is nothing for global clustering to
        // improve on, and the model load would cost more than it returns.
        guard highWaterMark >= 20 * Int(WAVEncoder.sampleRate) * 2 else {
            discard()
            return nil
        }
        return url
    }

    /// Delete the recording. Safe to call more than once.
    func discard() {
        try? handle?.close()
        handle = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        highWaterMark = 0
    }

    /// The 44-byte prefix WAVEncoder produces for a payload of `dataSize`.
    private static func header(dataSize: Int) -> Data {
        WAVEncoder.wavData(fromPCM: Data()).prefix(headerBytes).withPatchedSizes(dataSize: dataSize)
    }
}

private extension Data {
    /// Rewrite the two length fields a streamed WAV can't know up front: the
    /// RIFF chunk size (offset 4) and the data chunk size (offset 40).
    func withPatchedSizes(dataSize: Int) -> Data {
        var out = Data(self)
        guard out.count >= 44 else { return out }
        out.replaceSubrange(4..<8, with: UInt32(36 + dataSize).littleEndianBytes)
        out.replaceSubrange(40..<44, with: UInt32(dataSize).littleEndianBytes)
        return out
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        var v = littleEndian
        return withUnsafeBytes(of: &v) { Array($0) }
    }
}
