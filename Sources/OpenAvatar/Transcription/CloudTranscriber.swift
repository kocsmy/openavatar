import Foundation

/// Cloud STT via any OpenAI-compatible audio-transcriptions endpoint, BYO key.
/// The base-URL override means Deepgram/Groq-style OpenAI-compatible services
/// work without dedicated code paths (spec §4.2).
struct CloudTranscriber: Transcriber {
    let apiKey: String
    let baseURL: URL      // e.g. https://api.openai.com/v1
    let model: String     // e.g. whisper-1
    /// "auto" (omit language → server detects) or an ISO-639-1 code like "hu".
    var language: String = "auto"
    /// Decoder-bias context: names and jargon the server should spell
    /// correctly. Empty = omitted from the request.
    var prompt: String = ""

    func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSegment] {
        let wav = WAVEncoder.wavData(fromPCM: chunk.pcm)
        let boundary = "openavatar-\(UUID().uuidString)"

        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        addField("model", model)
        addField("response_format", "json")
        // Omit "language" for auto-detect; pass the ISO code otherwise.
        if language != "auto", !language.isEmpty {
            addField("language", language)
        }
        if !prompt.isEmpty {
            addField("prompt", prompt)
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"),
                                 timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AppError.http(status: status, body: Redactor.redact(String(data: data, encoding: .utf8) ?? ""))
        }

        let json = try JSONValue.parse(data)
        let text = (json["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [TranscriptSegment(text: text, t0: chunk.t0, t1: chunk.t1,
                                  source: chunk.source, confidence: 0.9)]
    }
}
